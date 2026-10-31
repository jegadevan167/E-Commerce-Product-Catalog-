{{
    config(
        materialized='view',
        alias='URBANTHREAD_PRODUCTS_NORMALIZED'
    )
}}

{{ catalogs_standardization(
    company_name = "URBANTHREAD", 
    source_call = source("SF_Source", "URBANTHREAD_PRODUCTS" ), 
    col_map = {
        'id': 'PRODUCT_CODE',
        'name': 'TITLE',
        'name_transform': 'TRIM(TITLE)',
        'brand': 'MANUFACTURER',
        'category': 'TYPE',
        'description': 'DETAILS',
        'price': 'RETAIL_PRICE',
        'color': 'COLOUR',
        'size': 'DIMENSIONS',
        'material': 'FABRIC',
        'in_stock': 'AVAILABILITY',
        'updated_at': 'LAST_MODIFIED'
    }
) }}