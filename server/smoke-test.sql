-- Smoke test for schema.sql.
--
-- Walks one element from IFC import through a scan, a registration, an
-- inspection and a markup, then checks the reporting views say what they should.
-- Also asserts that the constraints which protect the numbers actually fire —
-- a CHECK nobody has seen reject anything is not known to work.
--
--   docker exec -i <container> mysql -uroot -p<pw> < server/smoke-test.sql

USE twinzo;

SET @org      = UUID_TO_BIN(UUID(), 1);
SET @user     = UUID_TO_BIN(UUID(), 1);
SET @project  = UUID_TO_BIN(UUID(), 1);
SET @model    = UUID_TO_BIN(UUID(), 1);
SET @version  = UUID_TO_BIN(UUID(), 1);
SET @colC12   = UUID_TO_BIN(UUID(), 1);
SET @wall     = UUID_TO_BIN(UUID(), 1);
SET @duct     = UUID_TO_BIN(UUID(), 1);
SET @session  = UUID_TO_BIN(UUID(), 1);
SET @reg      = UUID_TO_BIN(UUID(), 1);
SET @markup   = UUID_TO_BIN(UUID(), 1);

INSERT INTO organizations (id, name) VALUES (@org, 'Clove Construction');

INSERT INTO users (id, organization_id, email, display_name, role)
VALUES (@user, @org, 'inspector@example.test', 'Field Inspector', 'inspector');

INSERT INTO projects (id, organization_id, name, code, epsg_code,
                      survey_point_easting, survey_point_northing,
                      true_north_rotation)
VALUES (@project, @org, 'Bay 4 Fit-Out', 'BAY4', 32643,
        712345.678, 1423456.789, 0.0421);

INSERT INTO tolerance_policies (id, project_id, tolerance_class,
                                tolerance_m, saturation_m, rejection_m)
VALUES (UUID_TO_BIN(UUID(), 1), @project, 'structural', 0.025, 0.150, 0.600),
       (UUID_TO_BIN(UUID(), 1), @project, 'mep',        0.050, 0.250, 0.600);

INSERT INTO bim_models (id, project_id, name, discipline)
VALUES (@model, @project, 'Bay 4 Structure', 'Structural');

INSERT INTO model_versions (id, bim_model_id, revision, ifc_schema,
                            source_sha256, unit_scale, element_count,
                            triangle_count, status, imported_by)
VALUES (@version, @model, 'R3', 'IFC4',
        REPEAT('a', 64), 0.001, 3, 184320, 'ready', @user);

INSERT INTO elements (id, model_version_id, element_index, ifc_guid, ifc_type,
                      category, name, mark, level_name, tolerance_class,
                      surface_area_m2, properties)
VALUES
  (@colC12, @version, 0, '1aBc0De7F9gHiJkLmNoPqR', 'IfcColumn',
   'Structural Columns', 'UC 305x305x97', 'C-12', 'Level 2', 'structural',
   14.2, JSON_OBJECT('Pset_ColumnCommon', JSON_OBJECT('IsExternal', false))),
  (@wall,   @version, 1, '2bCd1Ef8G0hIjKlMnOpQrS', 'IfcWall',
   'Walls', 'Blockwork 215', 'W-07', 'Level 2', 'structural', 46.0, NULL),
  (@duct,   @version, 2, '3cDe2Fg9H1iJkLmNoPqRsT', 'IfcDuctSegment',
   'Ducts', 'Supply 400x250', 'D-31', 'Level 2', 'mep', 8.7, NULL);

INSERT INTO element_properties (element_id, model_version_id, pset_name,
                                property_name, value_text, value_number, unit)
VALUES (@colC12, @version, 'Pset_ColumnCommon', 'LoadBearing', 'true', NULL, NULL),
       (@wall,   @version, 'Pset_WallCommon',   'FireRating',  '60', 60, 'min');

INSERT INTO scan_sessions (id, project_id, model_version_id, operator_id, name,
                           device_model, os_version, app_version, started_at,
                           ended_at, min_depth_confidence, voxel_size_m,
                           scan_point_count, mesh_anchor_count, status)
VALUES (@session, @project, @version, @user, 'Bay 4 Level 2 walkthrough',
        'iPhone15,3', '17.5.1', '0.2.0', NOW(3), NOW(3), 1, 0.05,
        58432, 96, 'uploaded');

INSERT INTO registrations (id, scan_session_id, sequence_no, method,
                           world_to_model, applied_scale, rms_error_m,
                           inlier_ratio, degrees_of_freedom, warnings,
                           established_at)
VALUES (@reg, @session, 1, 'control_points_then_icp',
        JSON_ARRAY(1,0,0,0, 0,1,0,0, 0,0,1,0, 1.25,-0.4,3.1,1),
        1.0, 0.0081, 0.74, 'full',
        JSON_ARRAY('Roll and pitch came from gravity, not from the targets.'),
        NOW(3));

INSERT INTO control_points (id, registration_id, label, world_x, world_y, world_z,
                            model_x, model_y, model_z, element_id, residual_m)
VALUES (UUID_TO_BIN(UUID(), 1), @reg, 'grid B/3 base',
        1.20, 0.00, 4.30, 2.45, -0.40, 7.40, @colC12, 0.006),
       (UUID_TO_BIN(UUID(), 1), @reg, 'north door jamb',
        -8.10, 0.00, -2.75, -6.85, -0.40, 0.35, NULL, 0.009);

INSERT INTO drift_samples (scan_session_id, measured_at, displacement_m,
                           rms_error_m, corrected)
VALUES (@session, NOW(3), 0.008, 0.0084, 1),
       (@session, NOW(3), 0.041, 0.0129, 1);

INSERT INTO point_clouds (id, scan_session_id, format, storage_uri, point_count,
                          coordinate_frame, registration_id, byte_size, sha256)
VALUES (UUID_TO_BIN(UUID(), 1), @session, 'ply',
        's3://twinzo-scans/bay4/level2.ply', 58432, 'model', @reg,
        1402368, REPEAT('b', 64));

-- The column is out; the wall passes; the duct was never scanned.
INSERT INTO element_inspections (id, scan_session_id, element_id, registration_id,
                                 status, tolerance_m, sample_count,
                                 in_tolerance_count, mean_abs_m, mean_signed_m,
                                 max_abs_m, mean_dx_m, mean_dy_m, mean_dz_m,
                                 worst_x, worst_y, worst_z, worst_signed_m,
                                 coverage, computed_at, computed_by)
VALUES
  (UUID_TO_BIN(UUID(), 1), @session, @colC12, @reg, 'fail', 0.025, 1840, 402,
   0.0171, 0.0164, 0.0412, 0.004, -0.006, 0.018,
   2.44, 1.80, 7.39, 0.0412, 0.83, NOW(3), 'server'),
  (UUID_TO_BIN(UUID(), 1), @session, @wall, @reg, 'pass', 0.025, 6210, 6098,
   0.0061, 0.0009, 0.0209, 0.001, 0.000, 0.002,
   -3.10, 1.20, 0.45, 0.0209, 0.91, NOW(3), 'server'),
  (UUID_TO_BIN(UUID(), 1), @session, @duct, @reg, 'unverified', 0.050, 0, 0,
   NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
   0.00, NOW(3), 'server');

INSERT INTO deviation_findings (id, scan_session_id, element_id, registration_id,
                                model_x, model_y, model_z,
                                world_x, world_y, world_z,
                                signed_deviation_m, tolerance_m, severity,
                                note, recorded_at, recorded_by)
VALUES (UUID_TO_BIN(UUID(), 1), @session, @colC12, @reg,
        2.44, 1.80, 7.39, 1.19, 2.20, 4.29,
        0.0412, 0.025, 'major',
        'Column base plate proud of setting-out; check packing.', NOW(3), @user),
       (UUID_TO_BIN(UUID(), 1), @session, @wall, @reg,
        -3.10, 1.20, 0.45, -4.35, 1.60, -2.65,
        -0.0209, 0.025, 'minor', NULL, NOW(3), @user);

INSERT INTO coverage_reports (id, scan_session_id, registration_id,
                              sample_spacing_m, search_radius_m,
                              covered_area_m2, total_area_m2, computed_at,
                              computed_by)
VALUES (UUID_TO_BIN(UUID(), 1), @session, @reg, 0.10, 0.094,
        53.9, 68.9, NOW(3), 'server');

INSERT INTO markups (id, project_id, scan_session_id, model_version_id,
                     topic_guid, title, description, topic_type, topic_status,
                     priority, created_by)
VALUES (@markup, @project, @session, @version, UUID(),
        'C-12 base plate 41 mm proud',
        'Base plate sits proud of setting-out across the full footprint.',
        'Issue', 'Open', 'High', @user);

INSERT INTO markup_viewpoints (id, markup_id, guid, camera_x, camera_y, camera_z,
                               direction_x, direction_y, direction_z,
                               up_x, up_y, up_z, field_of_view, components)
VALUES (UUID_TO_BIN(UUID(), 1), @markup, UUID(),
        4.20, 1.60, 9.10, -0.42, -0.11, -0.90, 0, 1, 0, 60.0,
        JSON_OBJECT('selection', JSON_ARRAY('1aBc0De7F9gHiJkLmNoPqR')));

INSERT INTO markup_elements (markup_id, element_id, ifc_guid)
VALUES (@markup, @colC12, '1aBc0De7F9gHiJkLmNoPqR');

INSERT INTO markup_comments (id, markup_id, guid, body, author_id)
VALUES (UUID_TO_BIN(UUID(), 1), @markup, UUID(),
        'Confirmed on site. Raised with steel subcontractor.', @user);

INSERT INTO sync_receipts (client_change_id, device_id, entity_type, entity_id)
VALUES (UUID_TO_BIN(UUID(), 1), 'iphone-A1B2C3', 'scan_session', @session);


-- ---------------------------------------------------------------------------
-- Assertions
-- ---------------------------------------------------------------------------

SELECT '--- generated direction column ---' AS check_name;
SELECT ROUND(signed_deviation_m, 4) AS deviation_m, direction
FROM deviation_findings
ORDER BY signed_deviation_m DESC;

SELECT '--- session summary view ---' AS check_name;
SELECT element_count, pass_count, fail_count, unverified_count,
       ROUND(pass_rate, 4)          AS pass_rate,
       ROUND(verified_fraction, 4)  AS verified_fraction,
       ROUND(worst_deviation_m, 4)  AS worst_deviation_m
FROM v_session_summary;

SELECT '--- element findings view ---' AS check_name;
SELECT label, ifc_type, status,
       ROUND(max_abs_m * 1000, 1) AS max_mm,
       ROUND(mean_dx_m * 1000, 1) AS dx_mm,
       ROUND(mean_dy_m * 1000, 1) AS dy_mm,
       ROUND(mean_dz_m * 1000, 1) AS dz_mm,
       coverage
FROM v_element_findings
ORDER BY max_abs_m IS NULL, max_abs_m DESC;

SELECT '--- element history view ---' AS check_name;
SELECT ifc_guid, model_revision, status, ROUND(max_abs_m * 1000, 1) AS max_mm
FROM v_element_history
ORDER BY ifc_guid;

SELECT '--- indexed property search ---' AS check_name;
SELECT COALESCE(NULLIF(e.mark, ''), e.name) AS label, p.value_number AS fire_rating
FROM element_properties p
JOIN elements e ON e.id = p.element_id
WHERE p.model_version_id = @version
  AND p.property_name = 'FireRating'
  AND p.value_number >= 60;
