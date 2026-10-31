{{
    config(
        materialized='incremental',
        unique_key='catalog_record_key',
        cluster_by=['brand_name', 'product_category'],
        alias='CATALOG_PRODCUTS_NORMALIZED',
        transient=false
    )
}}

{% set catalog_models = var('active_catalog_sources')%}

WITH unioned_catalogs AS (
    {% for model_name in catalog_models %}
        SELECT * FROM {{ ref(model_name) }}
        {% if not loop.last %} UNION ALL {% endif %}
    {% endfor %}
)

SELECT 
    catalog_record_key,
    source_system_name,
    source_product_id,
    product_name,
    normalized_product_name,
    brand_name,
    product_category,
    product_description,
    product_price,
    product_color,
    size_value,
    material_description,
    is_in_stock,
    source_last_modified_at,
    CONCAT_WS(' | ', 'Brand: ' || brand_name, 
        'Name: ' || normalized_product_name, 
        'Category: ' || product_category, 
        'Color: ' || COALESCE(product_color, ''), 
        'Size: ' || COALESCE(size_value, ''), 
        'Material: ' || COALESCE(material_description, ''),
        'Description: ' || COALESCE(product_description, '') 
    ) AS composite_text,
    CURRENT_TIMESTAMP() AS dbt_updated_at
FROM unioned_catalogs

{% if is_incremental() %}
WHERE source_last_modified_at > (SELECT COALESCE(MAX(source_last_modified_at), '2025-01-01'::TIMESTAMP_NTZ) FROM {{ this }})
{% endif %}