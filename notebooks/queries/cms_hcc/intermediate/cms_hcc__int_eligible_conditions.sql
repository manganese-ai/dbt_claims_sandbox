{{ config(
     enabled = var('cms_hcc_enabled',var('tuva_marts_enabled',True))
   )
}}
/*
Steps for staging condition data:
    1) Filter to risk-adjustable claims per claim type for the collection year.
    2) Gather diagnosis codes from condition for the eligible claims.
    3) Map and filter diagnosis codes to HCCs

Claims filtering logic:
 - Professional:
    - CPT/HCPCS in CPT/HCPCS seed file from CMS
 - Inpatient:
    - Bill type code in (11X, 41X)
 - Outpatient:
    - Bill type code in (12X, 13X, 43X, 71X, 73X, 76X, 77X, 85X)
    - CPT/HCPCS in CPT/HCPCS seed file from CMS

Jinja is used to set payment and collection year variables.
 - The hcc_model_version and payment_year vars have been set here
   so they get compiled.
 - The collection year is one year prior to the payment year.
*/

{% set model_version_compiled = var('cms_hcc_model_version') -%}
{% set payment_year_compiled = var('cms_hcc_payment_year') -%}
{% set collection_year = payment_year_compiled - 1 -%}

-- get raw medical claims data
with medical_claims as (

    select
          claim_id
        , claim_line_number
        , claim_type
        , patient_id
        , claim_start_date
        , claim_end_date
        , bill_type_code
        , hcpcs_code
    from {{ ref('cms_hcc__stg_medical_claim') }}

)

-- get raw conditions data (ICD 10 CM codes)
, conditions as (

    select
          claim_id
        , patient_id
        , code
    from {{ ref('cms_hcc__stg_core__condition') }}
    where code_type = 'icd-10-cm'

)

-- get seed data about HCPCS codes and the payment year
, cpt_hcpcs_list as (

    select
          payment_year
        , hcpcs_cpt_code
    from {{ ref('cms_hcc__cpt_hcpcs') }}

)

-- select professional claims that took place during the collection year and are covered during the payment year
, professional_claims as (

    select
          medical_claims.claim_id
        , medical_claims.claim_line_number
        , medical_claims.claim_type
        , medical_claims.patient_id
        , medical_claims.claim_start_date
        , medical_claims.claim_end_date
        , medical_claims.bill_type_code
        , medical_claims.hcpcs_code
    from medical_claims
         inner join cpt_hcpcs_list
         on medical_claims.hcpcs_code = cpt_hcpcs_list.hcpcs_cpt_code
    where claim_type = 'professional'
    and extract(year from claim_end_date) = {{ collection_year }}
    and cpt_hcpcs_list.payment_year = {{ payment_year_compiled }}

)

-- select inpatient claims that took place during the collection year and have bill types that refer to inpatient claims
, inpatient_claims as (

    select
          medical_claims.claim_id
        , medical_claims.claim_line_number
        , medical_claims.claim_type
        , medical_claims.patient_id
        , medical_claims.claim_start_date
        , medical_claims.claim_end_date
        , medical_claims.bill_type_code
        , medical_claims.hcpcs_code
    from medical_claims
    where claim_type = 'institutional'
    and extract(year from claim_end_date) = {{ collection_year }}
    and left(bill_type_code,2) in ('11','41') -- these bill types refer to inpatient claims

)

-- select outpatient claims that took place during the collection year, covered in the payment year, and have bill types that refer to outpatient claims
, outpatient_claims as (

    select
          medical_claims.claim_id
        , medical_claims.claim_line_number
        , medical_claims.claim_type
        , medical_claims.patient_id
        , medical_claims.claim_start_date
        , medical_claims.claim_end_date
        , medical_claims.bill_type_code
        , medical_claims.hcpcs_code
    from medical_claims
         inner join cpt_hcpcs_list
         on medical_claims.hcpcs_code = cpt_hcpcs_list.hcpcs_cpt_code
    where claim_type = 'institutional'
    and extract(year from claim_end_date) = {{ collection_year }}
    and cpt_hcpcs_list.payment_year = {{ payment_year_compiled }}
    and left(bill_type_code,2) in ('12','13','43','71','73','76','77','85') -- these bill types refer to outpatient claims

)

-- combine eligible claims 
, eligible_claims as (

    select * from professional_claims
    union all
    select * from inpatient_claims
    union all
    select * from outpatient_claims

)

-- add ICD-10 CM codes to each eligible patient claim
, eligible_conditions as (

    select distinct
          eligible_claims.claim_id
        , eligible_claims.patient_id
        , conditions.code
    from eligible_claims
         inner join conditions
         on eligible_claims.claim_id = conditions.claim_id
         and eligible_claims.patient_id = conditions.patient_id

)

-- cast data types appropriately
, add_data_types as (

    select distinct
          cast(patient_id as {{ dbt.type_string() }}) as patient_id
        , cast(code as {{ dbt.type_string() }}) as condition_code
        , cast('{{ model_version_compiled }}' as {{ dbt.type_string() }}) as model_version
        , cast('{{ payment_year_compiled }}' as integer) as payment_year
        , cast('{{ dbt_utils.pretty_time(format="%Y-%m-%d %H:%M:%S") }}' as {{ dbt.type_timestamp() }}) as date_calculated
    from eligible_conditions

)

-- final select
select
      patient_id
    , condition_code
    , model_version
    , payment_year
    , '{{ var('tuva_last_run')}}' as tuva_last_run
from add_data_types