CREATE FUNCTION otlet.portable_canonical_json_text(input jsonb) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
  SELECT CASE jsonb_typeof(portable_canonical_json_text.input)
    WHEN 'object' THEN '{' || COALESCE((
      SELECT string_agg(
        to_jsonb(entry.key)::text || ':' || otlet.portable_canonical_json_text(entry.value),
        ',' ORDER BY entry.key COLLATE "C"
      )
      FROM jsonb_each(portable_canonical_json_text.input) entry
    ), '') || '}'
    WHEN 'array' THEN '[' || COALESCE((
      SELECT string_agg(
        otlet.portable_canonical_json_text(item.value),
        ',' ORDER BY item.ordinality
      )
      FROM jsonb_array_elements(portable_canonical_json_text.input)
        WITH ORDINALITY item(value, ordinality)
    ), '') || ']'
    ELSE portable_canonical_json_text.input::text
  END
$$;

CREATE FUNCTION otlet.portable_text_hash(input text) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
  SELECT encode(sha256(convert_to(portable_text_hash.input, 'UTF8')), 'hex')
$$;

CREATE FUNCTION otlet.portable_json_hash(input jsonb) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
  SELECT otlet.portable_text_hash(otlet.portable_canonical_json_text(portable_json_hash.input))
$$;

CREATE FUNCTION otlet.json_schema_support_report(
  schema jsonb,
  current_path text DEFAULT '$'
) RETURNS TABLE (
  schema_path text,
  keyword text,
  error text
)
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  schema_key text;
  property record;
  type_name text;
  bound_name text;
  allowed_keywords constant text[] := ARRAY[
    '$schema', '$id', 'title', 'description', 'default', 'examples',
    'type', 'enum', 'const', 'required', 'properties', 'additionalProperties',
    'items', 'minLength', 'maxLength', 'minimum', 'maximum',
    'exclusiveMinimum', 'exclusiveMaximum', 'minItems', 'maxItems',
    'minProperties', 'maxProperties'
  ];
BEGIN
  IF jsonb_typeof(json_schema_support_report.schema) IS DISTINCT FROM 'object' THEN
    RETURN QUERY SELECT
      json_schema_support_report.current_path,
      '$schema'::text,
      json_schema_support_report.current_path || ' must be a schema object';
    RETURN;
  END IF;

  FOR schema_key IN
    SELECT key
    FROM jsonb_object_keys(json_schema_support_report.schema) key
    WHERE key <> ALL(allowed_keywords)
    ORDER BY key
  LOOP
    RETURN QUERY SELECT
      json_schema_support_report.current_path,
      schema_key,
      json_schema_support_report.current_path || ' uses unsupported keyword ' || schema_key;
  END LOOP;

  IF json_schema_support_report.schema ? 'type' THEN
    IF jsonb_typeof(json_schema_support_report.schema -> 'type') IS DISTINCT FROM 'string' THEN
      RETURN QUERY SELECT
        json_schema_support_report.current_path,
        'type'::text,
        json_schema_support_report.current_path || '.type must be one supported type name';
    ELSE
      type_name := json_schema_support_report.schema ->> 'type';
      IF type_name NOT IN ('object', 'array', 'string', 'number', 'integer', 'boolean', 'null') THEN
        RETURN QUERY SELECT
          json_schema_support_report.current_path,
          'type'::text,
          json_schema_support_report.current_path || '.type ' || type_name || ' is unsupported';
      END IF;
    END IF;
  END IF;

  IF json_schema_support_report.schema ? 'enum'
     AND (
       jsonb_typeof(json_schema_support_report.schema -> 'enum') IS DISTINCT FROM 'array'
       OR jsonb_array_length(json_schema_support_report.schema -> 'enum') = 0
     ) THEN
    RETURN QUERY SELECT
      json_schema_support_report.current_path,
      'enum'::text,
      json_schema_support_report.current_path || '.enum must be a non-empty array';
  END IF;

  IF json_schema_support_report.schema ? 'required'
     AND (
       jsonb_typeof(json_schema_support_report.schema -> 'required') IS DISTINCT FROM 'array'
       OR EXISTS (
         SELECT 1
         FROM jsonb_array_elements(json_schema_support_report.schema -> 'required') item(value)
         WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'string'
            OR NULLIF(item.value #>> '{}', '') IS NULL
       )
       OR jsonb_array_length(json_schema_support_report.schema -> 'required') IS DISTINCT FROM (
         SELECT count(DISTINCT item.value #>> '{}')::integer
         FROM jsonb_array_elements(json_schema_support_report.schema -> 'required') item(value)
       )
     ) THEN
    RETURN QUERY SELECT
      json_schema_support_report.current_path,
      'required'::text,
      json_schema_support_report.current_path || '.required must contain unique non-empty strings';
  END IF;

  IF json_schema_support_report.schema ? 'properties' THEN
    IF jsonb_typeof(json_schema_support_report.schema -> 'properties') IS DISTINCT FROM 'object' THEN
      RETURN QUERY SELECT
        json_schema_support_report.current_path,
        'properties'::text,
        json_schema_support_report.current_path || '.properties must be an object';
    ELSE
      FOR property IN
        SELECT key, value
        FROM jsonb_each(json_schema_support_report.schema -> 'properties')
        ORDER BY key
      LOOP
        RETURN QUERY
          SELECT *
          FROM otlet.json_schema_support_report(
            property.value,
            json_schema_support_report.current_path || '.properties.' || property.key
          );
      END LOOP;
    END IF;
  END IF;

  IF json_schema_support_report.schema ? 'additionalProperties'
     AND jsonb_typeof(json_schema_support_report.schema -> 'additionalProperties')
       IS DISTINCT FROM 'boolean' THEN
    RETURN QUERY SELECT
      json_schema_support_report.current_path,
      'additionalProperties'::text,
      json_schema_support_report.current_path || '.additionalProperties supports only true or false';
  END IF;

  IF json_schema_support_report.schema ? 'items' THEN
    IF jsonb_typeof(json_schema_support_report.schema -> 'items') IS DISTINCT FROM 'object' THEN
      RETURN QUERY SELECT
        json_schema_support_report.current_path,
        'items'::text,
        json_schema_support_report.current_path || '.items must be one schema object';
    ELSE
      RETURN QUERY
        SELECT *
        FROM otlet.json_schema_support_report(
          json_schema_support_report.schema -> 'items',
          json_schema_support_report.current_path || '.items'
        );
    END IF;
  END IF;

  FOREACH bound_name IN ARRAY ARRAY[
    'minLength', 'maxLength', 'minItems', 'maxItems', 'minProperties', 'maxProperties'
  ]
  LOOP
    IF json_schema_support_report.schema ? bound_name
       AND (
         jsonb_typeof(json_schema_support_report.schema -> bound_name) IS DISTINCT FROM 'number'
         OR (json_schema_support_report.schema ->> bound_name)::numeric < 0
         OR trunc((json_schema_support_report.schema ->> bound_name)::numeric)
           <> (json_schema_support_report.schema ->> bound_name)::numeric
       ) THEN
      RETURN QUERY SELECT
        json_schema_support_report.current_path,
        bound_name,
        json_schema_support_report.current_path || '.' || bound_name || ' must be a non-negative integer';
    END IF;
  END LOOP;

  FOREACH bound_name IN ARRAY ARRAY[
    'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum'
  ]
  LOOP
    IF json_schema_support_report.schema ? bound_name
       AND jsonb_typeof(json_schema_support_report.schema -> bound_name) IS DISTINCT FROM 'number' THEN
      RETURN QUERY SELECT
        json_schema_support_report.current_path,
        bound_name,
        json_schema_support_report.current_path || '.' || bound_name || ' must be a number';
    END IF;
  END LOOP;
END;
$$;

CREATE FUNCTION otlet.json_schema_validation_error(
  schema jsonb,
  instance jsonb,
  instance_path text DEFAULT '$'
) RETURNS text
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
  support_error text;
  expected_type text;
  actual_type text := jsonb_typeof(json_schema_validation_error.instance);
  required_name text;
  property record;
  item record;
  nested_error text;
  actual_number numeric;
  actual_length integer;
BEGIN
  SELECT report.error
  INTO support_error
  FROM otlet.json_schema_support_report(json_schema_validation_error.schema) report
  ORDER BY report.schema_path, report.keyword
  LIMIT 1;
  IF support_error IS NOT NULL THEN
    RETURN support_error;
  END IF;

  IF json_schema_validation_error.schema ? 'enum'
     AND NOT (json_schema_validation_error.schema -> 'enum') @>
       jsonb_build_array(json_schema_validation_error.instance) THEN
    RETURN json_schema_validation_error.instance_path || ' is not one of the allowed values';
  END IF;
  IF json_schema_validation_error.schema ? 'const'
     AND json_schema_validation_error.instance IS DISTINCT FROM
       json_schema_validation_error.schema -> 'const' THEN
    RETURN json_schema_validation_error.instance_path || ' does not match const';
  END IF;

  expected_type := json_schema_validation_error.schema ->> 'type';
  IF expected_type IS NOT NULL THEN
    IF expected_type = 'integer' THEN
      IF actual_type IS DISTINCT FROM 'number'
         OR (json_schema_validation_error.instance #>> '{}')::numeric <>
           trunc((json_schema_validation_error.instance #>> '{}')::numeric) THEN
        RETURN json_schema_validation_error.instance_path || ' must be an integer';
      END IF;
    ELSIF expected_type = 'number' THEN
      IF actual_type IS DISTINCT FROM 'number' THEN
        RETURN json_schema_validation_error.instance_path || ' must be a number';
      END IF;
    ELSIF actual_type IS DISTINCT FROM expected_type THEN
      RETURN json_schema_validation_error.instance_path || ' must be ' || expected_type;
    END IF;
  END IF;

  IF actual_type = 'object' THEN
    FOR required_name IN
      SELECT value
      FROM jsonb_array_elements_text(
        COALESCE(json_schema_validation_error.schema -> 'required', '[]'::jsonb)
      ) item(value)
    LOOP
      IF NOT json_schema_validation_error.instance ? required_name THEN
        RETURN json_schema_validation_error.instance_path || ' is missing required property ' || required_name;
      END IF;
    END LOOP;

    IF json_schema_validation_error.schema -> 'additionalProperties' = 'false'::jsonb THEN
      SELECT key
      INTO required_name
      FROM jsonb_object_keys(json_schema_validation_error.instance) key
      WHERE NOT COALESCE(json_schema_validation_error.schema -> 'properties', '{}'::jsonb) ? key
      ORDER BY key
      LIMIT 1;
      IF required_name IS NOT NULL THEN
        RETURN json_schema_validation_error.instance_path || ' has unsupported property ' || required_name;
      END IF;
    END IF;

    FOR property IN
      SELECT definition.key, definition.value AS schema, value.value AS instance
      FROM jsonb_each(COALESCE(json_schema_validation_error.schema -> 'properties', '{}'::jsonb)) definition
      JOIN jsonb_each(json_schema_validation_error.instance) value ON value.key = definition.key
      ORDER BY definition.key
    LOOP
      nested_error := otlet.json_schema_validation_error(
        property.schema,
        property.instance,
        json_schema_validation_error.instance_path || '.' || property.key
      );
      IF nested_error IS NOT NULL THEN
        RETURN nested_error;
      END IF;
    END LOOP;

    SELECT count(*)::integer
    INTO actual_length
    FROM jsonb_object_keys(json_schema_validation_error.instance);
    IF json_schema_validation_error.schema ? 'minProperties'
       AND actual_length < (json_schema_validation_error.schema ->> 'minProperties')::integer THEN
      RETURN json_schema_validation_error.instance_path || ' has too few properties';
    END IF;
    IF json_schema_validation_error.schema ? 'maxProperties'
       AND actual_length > (json_schema_validation_error.schema ->> 'maxProperties')::integer THEN
      RETURN json_schema_validation_error.instance_path || ' has too many properties';
    END IF;
  END IF;

  IF actual_type = 'array' THEN
    actual_length := jsonb_array_length(json_schema_validation_error.instance);
    IF json_schema_validation_error.schema ? 'minItems'
       AND actual_length < (json_schema_validation_error.schema ->> 'minItems')::integer THEN
      RETURN json_schema_validation_error.instance_path || ' has too few items';
    END IF;
    IF json_schema_validation_error.schema ? 'maxItems'
       AND actual_length > (json_schema_validation_error.schema ->> 'maxItems')::integer THEN
      RETURN json_schema_validation_error.instance_path || ' has too many items';
    END IF;
    IF json_schema_validation_error.schema ? 'items' THEN
      FOR item IN
        SELECT value, ordinality
        FROM jsonb_array_elements(json_schema_validation_error.instance)
          WITH ORDINALITY item(value, ordinality)
      LOOP
        nested_error := otlet.json_schema_validation_error(
          json_schema_validation_error.schema -> 'items',
          item.value,
          format('%s[%s]', json_schema_validation_error.instance_path, item.ordinality - 1)
        );
        IF nested_error IS NOT NULL THEN
          RETURN nested_error;
        END IF;
      END LOOP;
    END IF;
  END IF;

  IF actual_type = 'string' THEN
    actual_length := char_length(json_schema_validation_error.instance #>> '{}');
    IF json_schema_validation_error.schema ? 'minLength'
       AND actual_length < (json_schema_validation_error.schema ->> 'minLength')::integer THEN
      RETURN json_schema_validation_error.instance_path || ' is shorter than minLength';
    END IF;
    IF json_schema_validation_error.schema ? 'maxLength'
       AND actual_length > (json_schema_validation_error.schema ->> 'maxLength')::integer THEN
      RETURN json_schema_validation_error.instance_path || ' is longer than maxLength';
    END IF;
  END IF;

  IF actual_type = 'number' THEN
    actual_number := (json_schema_validation_error.instance #>> '{}')::numeric;
    IF json_schema_validation_error.schema ? 'minimum'
       AND actual_number < (json_schema_validation_error.schema ->> 'minimum')::numeric THEN
      RETURN json_schema_validation_error.instance_path || ' is below minimum';
    END IF;
    IF json_schema_validation_error.schema ? 'maximum'
       AND actual_number > (json_schema_validation_error.schema ->> 'maximum')::numeric THEN
      RETURN json_schema_validation_error.instance_path || ' is above maximum';
    END IF;
    IF json_schema_validation_error.schema ? 'exclusiveMinimum'
       AND actual_number <= (json_schema_validation_error.schema ->> 'exclusiveMinimum')::numeric THEN
      RETURN json_schema_validation_error.instance_path || ' is not above exclusiveMinimum';
    END IF;
    IF json_schema_validation_error.schema ? 'exclusiveMaximum'
       AND actual_number >= (json_schema_validation_error.schema ->> 'exclusiveMaximum')::numeric THEN
      RETURN json_schema_validation_error.instance_path || ' is not below exclusiveMaximum';
    END IF;
  END IF;

  RETURN NULL;
END;
$$;
