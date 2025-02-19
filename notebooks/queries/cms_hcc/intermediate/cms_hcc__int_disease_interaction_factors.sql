{{ config(
     enabled = var('cms_hcc_enabled',var('tuva_marts_enabled',True))
   )
}}
/*
The hcc_model_version var has been set here so it gets compiled.
*/

{% set model_version_compiled = var('cms_hcc_model_version') -%}

-- pull in demographic data
with demographics as (

    select
          patient_id
        , enrollment_status
        , gender
        , age_group
        , medicaid_status
        , dual_status
        , orec
        , institutional_status
        , enrollment_status_default
        , medicaid_dual_status_default
        , institutional_status_default
        , model_version
        , payment_year
    from {{ ref('cms_hcc__int_demographic_factors') }}

)

-- pull in HCC hierarchy data 
, hcc_hierarchy as (

    select
          patient_id
        , hcc_code
    from {{ ref('cms_hcc__int_hcc_hierarchy') }}

)

-- get seed data that gives coefficients for combinations of multiple HCC codes (e.g., Immune Disorders (HCC 47) and Cancer (HCCs 8-12)) and patient info (e.g., OREC, institutional status) for Continuing enrollees
, seed_interaction_factors as (

    select
          model_version
        , enrollment_status
        , medicaid_status
        , dual_status
        , orec
        , institutional_status
        , short_name
        , description
        , hcc_code_1
        , hcc_code_2
        , coefficient
    from {{ ref('cms_hcc__disease_interaction_factors') }}
    where model_version = '{{ model_version_compiled }}'

)

-- combine demographic and HCC info for each patient
, demographics_with_hccs as (

    select
          demographics.patient_id
        , demographics.enrollment_status
        , demographics.medicaid_status
        , demographics.dual_status
        , demographics.orec
        , demographics.institutional_status
        , demographics.enrollment_status_default
        , demographics.medicaid_dual_status_default
        , demographics.institutional_status_default
        , demographics.model_version
        , demographics.payment_year
        , hcc_hierarchy.hcc_code
    from demographics
         inner join hcc_hierarchy
         on demographics.patient_id = hcc_hierarchy.patient_id

)

-- add disease interaction-related coefficients to patient data
, demographics_with_interactions as (

    select
          demographics_with_hccs.patient_id
        , demographics_with_hccs.model_version
        , demographics_with_hccs.payment_year
        , interactions_code_1.description
        , interactions_code_1.hcc_code_1
        , interactions_code_1.hcc_code_2
        , interactions_code_1.coefficient
    from demographics_with_hccs
         inner join seed_interaction_factors as interactions_code_1
         on demographics_with_hccs.enrollment_status = interactions_code_1.enrollment_status
         and demographics_with_hccs.medicaid_status = interactions_code_1.medicaid_status
         and demographics_with_hccs.dual_status = interactions_code_1.dual_status
         and demographics_with_hccs.orec = interactions_code_1.orec
         and demographics_with_hccs.institutional_status = interactions_code_1.institutional_status
         and demographics_with_hccs.hcc_code = interactions_code_1.hcc_code_1

)

-- continue matching disease interaction-related coefficients to patient data
-- not quite sure why we need this cte (something with the second hcc code, whereas the cte above is the first hcc code)
, disease_interactions as (

    select
          demographics_with_interactions.patient_id
        , demographics_with_interactions.hcc_code_1
        , demographics_with_interactions.hcc_code_2
        , demographics_with_interactions.description
        , demographics_with_interactions.coefficient
        , demographics_with_interactions.model_version
        , demographics_with_interactions.payment_year
    from demographics_with_interactions
        inner join demographics_with_hccs as interactions_code_2
        on demographics_with_interactions.patient_id = interactions_code_2.patient_id
        and demographics_with_interactions.hcc_code_2 = interactions_code_2.hcc_code
)

-- cast appropriately
, add_data_types as (

    select
          cast(patient_id as {{ dbt.type_string() }}) as patient_id
        , cast(hcc_code_1 as {{ dbt.type_string() }}) as hcc_code_1
        , cast(hcc_code_2 as {{ dbt.type_string() }}) as hcc_code_2
        , cast(description as {{ dbt.type_string() }}) as description
        , round(cast(coefficient as {{ dbt.type_numeric() }}),3) as coefficient
        , cast(model_version as {{ dbt.type_string() }}) as model_version
        , cast(payment_year as integer) as payment_year
        , cast('{{ dbt_utils.pretty_time(format="%Y-%m-%d %H:%M:%S") }}' as {{ dbt.type_timestamp() }}) as date_calculated
    from disease_interactions

)

-- final select
select
      patient_id
    , hcc_code_1
    , hcc_code_2
    , description
    , coefficient
    , model_version
    , payment_year
    , '{{ var('tuva_last_run')}}' as tuva_last_run
from add_data_types