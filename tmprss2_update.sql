USE clinical_merge_v5_240919;
SET @date = '2020-06-30';
SET SQL_MODE = '';

-- ----------------------------------------------------------------------------
-- Make a table with the drugs of interest
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS user_mnz2108.tmprss2_drugs;

CREATE TABLE user_mnz2108.tmprss2_drugs
(
    drug_name       VARCHAR(255) NOT NULL,
    drug_concept_id INT(11)      NOT NULL
);

INSERT INTO user_mnz2108.tmprss2_drugs (drug_name, drug_concept_id)
VALUES ('Vitamin D', 21600815),
       ('androgen', 21602506),
       ('Gonadotropin releasing hormone analogues', 21603823),
       ('Other hormone antagonists and related agents', 21603845),
       ('anti TNF-alpha', 21603907),
       ('B-raf inhibitor', 40253397),
       ('MEK1/2 inhibitor', 43534814),
       ('Up-regulate', 21602506),
       ('Up-regulate', 40253397),
       ('Up-regulate', 35807225),
       ('Up-regulate', 21603809),
       ('Up-regulate', 40253431),
       ('Up-regulate', 21603810),
       ('Up-regulate', 1588658),
       ('Up-regulate', 43534814),
       ('Up-regulate', 21603900),
       ('Up-regulate', 21603781),
       ('Up-regulate', 43534809),
       ('Up-regulate', 21603897),
       ('Up-regulate', 21603780),
       ('Up-regulate', 21600815),
       ('Estrogen/progesterone', 21602514),
       ('Estrogen/progesterone', 21602473),
       ('Estrogen/progesterone', 21602488),
       ('anti-androgen', 21602674),
       ('anti-androgen', 21603834),
       ('anti-androgen', 21603845),
       ('anti-androgen', 21603078),
       ('anti-androgen', 21601534),
       ('anti-androgen', 21602614),
       ('Anti-androgen + estrogen', 21602674),
       ('Anti-androgen + estrogen', 21603834),
       ('Anti-androgen + estrogen', 21603845),
       ('Anti-androgen + estrogen', 21603078),
       ('Anti-androgen + estrogen', 21601534),
       ('Anti-androgen + estrogen', 21602614),
       ('Anti-androgen + estrogen', 21603823),
       ('Anti-androgen + estrogen', 21603845),
       ('Anti-androgen + estrogen', 21602514),
       ('Anti-androgen + estrogen', 21602473),
       ('Anti-androgen + estrogen', 21602488),
       ('HDAC inhibitor', 21603809),
       ('HDAC inhibitor', 40253431),
       ('HDAC inhibitor', 21603810),
       ('HDAC inhibitor', 1588658),
       ('mTOR inhibitor', 21603900),
       ('mTOR inhibitor', 21603781),
       ('mTOR inhibitor', 43534809),
       ('mTOR inhibitor', 21603897),
       ('mTOR inhibitor', 21603780),
       ('EGFR inhibitor', 35807225),
       ('ALK/ROS1 inhibitor', 40253398),
       ('ALK/ROS1 inhibitor', 715838),
       ('ALK/ROS1 inhibitor', 715810),
       ('Down-regulate', 40253398),
       ('Down-regulate', 715838),
       ('Down-regulate', 715810),
       ('Down-regulate', 21603907),
       ('Down-regulate', 21602674),
       ('Down-regulate', 21603834),
       ('Down-regulate', 21603845),
       ('Down-regulate', 21603078),
       ('Down-regulate', 21601534),
       ('Down-regulate', 21602614),
       ('Down-regulate', 21603823),
       ('Down-regulate', 21603845),
       ('Down-regulate', 21602514),
       ('Down-regulate', 21602473),
       ('Down-regulate', 21602488),
       ('Anti-interleukins', 1588690),
       ('Anti-interleukins', 1123622),
       ('Anti-interleukins', 40253794);

-- ----------------------------------------------------------------------------
-- Cache patients of interest
-- ----------------------------------------------------------------------------

-- Infection tests for SARS-COV-2 (used multiple times)
-- Only at positive patients, so use earliest positive test
DROP TABLE IF EXISTS user_mnz2108.tmprss2_infected_patients;

CREATE TABLE user_mnz2108.tmprss2_infected_patients AS
SELECT pat_mrn_id, person_id, MIN(result_date) AS cov_result_date
FROM `2_covid_labs_noname`
         LEFT JOIN `2_covid_patient2person` USING (pat_mrn_id)
WHERE date_retrieved <= @date
  AND ord_value LIKE 'Detected%'
GROUP BY pat_mrn_id, person_id;

CREATE INDEX pat_mrn_id ON user_mnz2108.tmprss2_infected_patients (pat_mrn_id);
CREATE INDEX person_id ON user_mnz2108.tmprss2_infected_patients (person_id);

-- ----------------------------------------------------------------------------
-- Cache exposures to the drugs of interest
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS user_mnz2108.tmprss2_drug_exposures;

CREATE TABLE IF NOT EXISTS user_mnz2108.tmprss2_drug_exposures AS
# From OMOP table
SELECT DISTINCT pat_mrn_id,
                user_mnz2108.tmprss2_drugs.drug_concept_id AS drug_class_concept_id,
                drug_name                                  AS drug_class_name,
                drug_era.drug_concept_id,
                concept_name                               AS drug_name
FROM user_mnz2108.tmprss2_drugs
         INNER JOIN concept_ancestor ON drug_concept_id = ancestor_concept_id
         INNER JOIN drug_era ON descendant_concept_id = drug_era.drug_concept_id
         INNER JOIN concept ON drug_era.drug_concept_id = concept_id
         INNER JOIN user_mnz2108.tmprss2_infected_patients USING (person_id)
WHERE (YEAR(drug_era_start_datetime) >= 2019 OR YEAR(drug_era_end_datetime) >= 2019)
  AND person_id IS NOT NULL
UNION
# From COVID table
SELECT DISTINCT pat_mrn_id,
                drug_concept_id AS drug_class_concept_id,
                drug_name       AS drug_class_name,
                concept_id      AS drug_concept_id,
                concept_name    AS drug_name
FROM user_mnz2108.tmprss2_drugs
         INNER JOIN concept_ancestor ON drug_concept_id = ancestor_concept_id
         INNER JOIN concept ON descendant_concept_id = concept_id
         INNER JOIN `2_covid_med_id2rxnorm` ON concept_code = rxnorm
         INNER JOIN `2_covid_meds_noname` USING (med_id)
         INNER JOIN user_mnz2108.tmprss2_infected_patients USING (pat_mrn_id)
WHERE date_retrieved <= @date
  AND vocabulary_id = 'RxNorm';

-- ----------------------------------------------------------------------------
-- Cache complete analysis table
-- Tables:
-- 1. Demographics (temporary)
-- 2. COV start to intubation (temporary)
-- 3. COV start to death (temporary)
-- 4. Complete table (All the above joined)
-- ----------------------------------------------------------------------------

# Demographics table
DROP TABLE IF EXISTS tmprss2_demographics;

CREATE TEMPORARY TABLE tmprss2_demographics AS
SELECT pat_mrn_id,
       IF(sex_desc = 'Male', 1.0, 0.0)                         AS male_sex,
       -- Either current age or age at death
       DATEDIFF(COALESCE(death_date, @date), birth_date) / 365 AS age,
       CASE
           WHEN ethnicity = 'HISPANIC OR LATINO OR SPANISH ORIGIN' THEN 'hs'
           WHEN ethnicity = 'NOT HISPANIC OR LATINO OR SPANISH ORIGIN' THEN 'nonhs'
           WHEN ethnicity = '(null)' THEN 'missing'
           WHEN ethnicity = 'DECLINED' THEN 'missing'
           WHEN ethnicity = 'UNKNOWN' THEN 'missing'
           -- These are all small minority responses
           ELSE 'other'
           END                                                 AS ethnicity,
       CASE
           WHEN race_1 = 'WHITE' THEN 'white'
           WHEN race_1 = 'BLACK OR AFRICAN AMERICAN' THEN 'black_aa'
           WHEN race_1 = 'ASIAN' THEN 'asian'
           WHEN race_1 = 'DECLINED' THEN 'missing'
           WHEN race_1 = '(null)' THEN 'missing'
           -- These are all small minority responses
           ELSE 'other'
           END                                                 AS race
FROM `2_covid_persons_noname`
         INNER JOIN user_mnz2108.tmprss2_infected_patients USING (pat_mrn_id)
WHERE sex_desc IN ('Male', 'Female');


-- COV start to intubation. Earliest >= -14 days from the first positive diagnosis/test result
DROP TABLE IF EXISTS cov_start_to_intubation;

CREATE TEMPORARY TABLE cov_start_to_intubation AS
SELECT pat_mrn_id,
       DATEDIFF(COALESCE(MIN(order_date), @date), MIN(cov_result_date)) AS cov_start_to_intubation,
       IF(MAX(order_proc_id) IS NULL, 0.0, 1.0)                         AS intubated
FROM user_mnz2108.tmprss2_infected_patients
         LEFT JOIN `2_covid_intubation_orders_noname` USING (pat_mrn_id)
WHERE COALESCE(date_retrieved, @date) <= @date
  AND DATEDIFF(COALESCE(order_date, @date), cov_result_date) > -14
GROUP BY pat_mrn_id;


-- COV start to death.
DROP TABLE IF EXISTS cov_start_to_death;

CREATE TEMPORARY TABLE cov_start_to_death AS
SELECT pat_mrn_id,
       DATEDIFF(COALESCE(death_date, @date), cov_result_date) AS cov_start_to_death,
       IF(death_date IS NULL, 0.0, 1.0)                       AS died
FROM user_mnz2108.tmprss2_infected_patients
         INNER JOIN `2_covid_persons_noname` USING (pat_mrn_id);


-- Cache complete table
DROP TABLE IF EXISTS user_mnz2108.tmprss2_complete;

CREATE TABLE user_mnz2108.tmprss2_complete AS
SELECT *
FROM tmprss2_demographics
         INNER JOIN cov_start_to_intubation USING (pat_mrn_id)
         INNER JOIN cov_start_to_death USING (pat_mrn_id);

-- Drop tables only needed for a couple queries
DROP TABLE IF EXISTS user_mnz2108.tmprss2_infected_patients;


-- ----------------------------------------------------------------------------
-- Conditions for propensity matching
-- ----------------------------------------------------------------------------

DROP TABLE IF EXISTS user_mnz2108.tmprss2_match_conditions;

CREATE TABLE user_mnz2108.tmprss2_match_conditions AS
SELECT icd10
FROM (
         SELECT pat_mrn_id, REPLACE(REPLACE(icd10_code, ',', ''), ' ', '') AS icd10
         FROM `2_covid_patients_noname`
     ) AS occurrences
GROUP BY icd10
HAVING COUNT(DISTINCT pat_mrn_id) > 500;


DROP TABLE IF EXISTS user_mnz2108.tmprss2_match_condition_occurrences;

CREATE TABLE user_mnz2108.tmprss2_match_condition_occurrences AS
SELECT DISTINCT pat_mrn_id, icd10
FROM user_mnz2108.tmprss2_match_conditions
         INNER JOIN `2_covid_patients_noname` ON icd10 = REPLACE(REPLACE(icd10_code, ',', ''), ' ', '');


-- ----------------------------------------------------------------------------
-- Analysis begins
-- Counts at the class and individual drug levels
-- ----------------------------------------------------------------------------

-- Counts at the class level
DROP TABLE IF EXISTS user_mnz2108.tmprss2_class_aggregate;

CREATE TABLE user_mnz2108.tmprss2_class_aggregate AS
SELECT drug_class_name, COUNT(DISTINCT pat_mrn_id) AS N
FROM user_mnz2108.tmprss2_drug_exposures
GROUP BY drug_class_name
ORDER BY N DESC;

-- Counts at the drug level
DROP TABLE IF EXISTS user_mnz2108.tmprss2_drug_aggregate;

CREATE TABLE user_mnz2108.tmprss2_drug_aggregate AS
SELECT drug_class_name,
       drug_name,
       drug_concept_id,
       drug_counts.N,
       CAST(100 * drug_counts.N / tmprss2_class_aggregate.N AS DECIMAL(5, 2)) AS percent_of_class
FROM (
         SELECT drug_class_name, drug_concept_id, drug_name, COUNT(DISTINCT pat_mrn_id) AS N
         FROM user_mnz2108.tmprss2_drug_exposures
         GROUP BY drug_class_name, drug_concept_id, drug_name
     ) AS drug_counts
         INNER JOIN user_mnz2108.tmprss2_class_aggregate USING (drug_class_name)
ORDER BY drug_class_name;
