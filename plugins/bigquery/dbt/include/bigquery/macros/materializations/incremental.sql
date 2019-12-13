
{% materialization incremental, adapter='bigquery' -%}

  {%- set unique_key = config.get('unique_key') -%}
  {%- set full_refresh_mode = (flags.FULL_REFRESH == True) -%}

  {%- set target_relation = this %}
  {%- set existing_relation = load_relation(this) %}
  {%- set tmp_relation = make_temp_relation(this) %}

  {%- set partition_by = config.get('partition_by', none) -%}
  {%- set cluster_by = config.get('cluster_by', none) -%}
  {%- set min_source_partition = none -%}

  {{ run_hooks(pre_hooks) }}

  {% if existing_relation is none %}
      {% set build_sql = create_table_as(False, target_relation, sql) %}
  {% elif existing_relation.is_view %}
      {#-- There's no way to atomically replace a view with a table on BQ --#}
      {{ adapter.drop_relation(existing_relation) }}
      {% set build_sql = create_table_as(False, target_relation, sql) %}
  {% elif full_refresh_mode %}
      {#-- If the partition/cluster config has changed, then we must drop and recreate --#}
      {% if not adapter.is_replaceable(existing_relation, partition_by, cluster_by) %}
          {% do log("Hard refreshing " ~ existing_relation ~ " because it is not replaceable") %}
          {{ adapter.drop_relation(existing_relation) }}
      {% endif %}
      {% set build_sql = create_table_as(False, target_relation, sql) %}
  {% else %}
     {% set dest_columns = adapter.get_columns_in_relation(existing_relation) %}
     
     {%- set dest_partition = none -%}
     
     {#-- if partitioned, get the range of partition values to be updated --#}
     {% if partition_by %}
         {#-- If the temp relation exists and its partition/cluster config of the temp relation 
         has changed, then we must drop and recreate --#}
         {% if not adapter.is_replaceable(tmp_relation, partition_by, cluster_by) %}
             {% do log("Hard refreshing " ~ tmp_relation ~ " because it is not replaceable") %}
             {{ adapter.drop_relation(tmp_relation) }}
         {% endif %}
         {% do run_query(create_table_as(True, tmp_relation, sql)) %}

         {% set get_partition_range %}
            select min({{partition_by}}), max({{partition_by}}) from {{tmp_relation}}
         {% endset %}
         
         {% set partition_range = run_query(get_partition_range)[0] %}
         {% set partition_min, partition_max = partition_range[0]|string, partition_range[1]|string %}
         
         {% set p = modules.re.compile(
             '([ ]?date[ ]?\([ ]?)?(\w+)(?:[ ]?\)[ ]?)?', 
             modules.re.IGNORECASE) %}
         {% set m = p.match(partition_by) %}
         {% set cast_to_date = ('date' in m.group(1)|lower) %}
         {% set partition_colname = m.group(2) %}
         
         {% if partition_min|lower != 'null' and partition_max|lower != 'null' %}
            {%- set dest_partition = {
                'name': partition_colname,
                'cast_to_date': cast_to_date,
                'min': partition_min,
                'max': partition_max
                } -%}
          {% endif %}
          
          {%- set source_sql -%}
            (
              select * from {{tmp_relation}}
            )
          {%- endset -%}
          
      {% else %}
      
          {#-- wrap sql in parens to make it a subquery --#}
          {%- set source_sql -%}
            (
              {{sql}}
            )
          {%- endset -%}
          
      {% endif %}
     
     {% set build_sql = get_merge_sql(target_relation, source_sql, unique_key, dest_columns, dest_partition) %}
  {% endif %}

  {%- call statement('main') -%}
    {{ build_sql }}
  {% endcall %}

  {{ run_hooks(post_hooks) }}

  {{ return({'relations': [target_relation]}) }}

{%- endmaterialization %}
