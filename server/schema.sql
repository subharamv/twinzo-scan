-- Twinzo Scan — MySQL 8.0 schema
--
-- Covers M01/M02 (BIM import and versioning), M12 (element identification),
-- M14 (storage and sync) and M15 (reporting) from the module plan, plus the
-- markup and coverage records the field workflow needs.
--
-- Conventions, applied throughout:
--
--   * Identifiers are BINARY(16). Generate them as UUID_TO_BIN(UUID(), 1) —
--     the trailing 1 swaps the time-low and time-high fields so v1 UUIDs sort
--     chronologically, which keeps InnoDB's clustered index appending rather
--     than writing into the middle of the tree. Read them back with
--     BIN_TO_UUID(id, 1).
--   * Lengths are metres, stored as DOUBLE. Not DECIMAL: these are measurements
--     with a known error budget of millimetres, not currency, and the arithmetic
--     is done in the client anyway.
--   * Every table carries created_at / updated_at. Inspection records are
--     evidence, and evidence without a timestamp is an assertion.
--   * Deletes are soft where the row is evidence (scans, findings, markups) and
--     hard where the row is derived (element_inspections, coverage). A finding
--     an inspector filed must remain reconstructible; a number the app computed
--     can always be recomputed.
--
-- Run against MySQL 8.0.17 or later: earlier versions ignore CHECK constraints.

SET NAMES utf8mb4;
SET time_zone = '+00:00';

CREATE DATABASE IF NOT EXISTS twinzo
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;
USE twinzo;


-- ============================================================================
-- Tenancy and people
-- ============================================================================

CREATE TABLE organizations (
  id            BINARY(16)   NOT NULL,
  name          VARCHAR(200) NOT NULL,
  created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                             ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id)
) ENGINE = InnoDB;

CREATE TABLE users (
  id              BINARY(16)   NOT NULL,
  organization_id BINARY(16)   NOT NULL,
  email           VARCHAR(320) NOT NULL,
  display_name    VARCHAR(200) NOT NULL,
  -- Who may sign off an inspection is a contractual question, not a UI one.
  role            ENUM('viewer','inspector','engineer','admin')
                               NOT NULL DEFAULT 'inspector',
  is_active       TINYINT(1)   NOT NULL DEFAULT 1,
  created_at      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                               ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_users_email (email),
  KEY ix_users_org (organization_id),
  CONSTRAINT fk_users_org FOREIGN KEY (organization_id)
    REFERENCES organizations (id) ON DELETE RESTRICT
) ENGINE = InnoDB;


-- ============================================================================
-- Projects and geo-referencing
-- ============================================================================

-- The single largest source of "the model is in the wrong place" is not the
-- alignment algorithm — it is that nobody wrote down where the model's origin
-- is. Revit carries a project base point, a survey point and a true-north
-- rotation, and an IFC export can carry any of the three depending on how it
-- was configured. Recording them per project means a scan taken by one crew can
-- be compared against one taken by another six months later.
CREATE TABLE projects (
  id                    BINARY(16)   NOT NULL,
  organization_id       BINARY(16)   NOT NULL,
  name                  VARCHAR(200) NOT NULL,
  code                  VARCHAR(64)  NULL,
  description           TEXT         NULL,

  -- Shared coordinates. epsg_code names the projected CRS the survey point sits
  -- in; NULL means the project is on local coordinates only and scans from it
  -- cannot be placed on a map.
  epsg_code             INT          NULL,
  survey_point_easting  DOUBLE       NULL,
  survey_point_northing DOUBLE       NULL,
  survey_point_elevation DOUBLE      NULL,
  -- Offset from the model origin to the project base point, model units.
  base_point_x          DOUBLE       NOT NULL DEFAULT 0,
  base_point_y          DOUBLE       NOT NULL DEFAULT 0,
  base_point_z          DOUBLE       NOT NULL DEFAULT 0,
  -- Radians, counter-clockwise from project north to true north.
  true_north_rotation   DOUBLE       NOT NULL DEFAULT 0,

  created_at            TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at            TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                                     ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_projects_org_code (organization_id, code),
  KEY ix_projects_org (organization_id),
  CONSTRAINT fk_projects_org FOREIGN KEY (organization_id)
    REFERENCES organizations (id) ON DELETE RESTRICT
) ENGINE = InnoDB;


-- Per-project acceptance limits. The app ships defaults; a project overrides
-- them, because a data centre and a warehouse are signed off very differently.
-- Rows are matched most-specific-first: ifc_type, then category, then class.
CREATE TABLE tolerance_policies (
  id                BINARY(16)  NOT NULL,
  project_id        BINARY(16)  NOT NULL,
  tolerance_class   ENUM('structural','mep','finishes','unclassified') NOT NULL,
  -- Optional narrowing; the empty string matches anything in the class.
  --
  -- Empty string rather than NULL, and the distinction is load-bearing: MySQL
  -- treats NULLs as distinct in a unique index, so a nullable narrowing column
  -- would let a project accumulate any number of conflicting class-wide policies
  -- under a constraint that looks like it forbids exactly that.
  ifc_type          VARCHAR(64)  NOT NULL DEFAULT '',
  category          VARCHAR(128) NOT NULL DEFAULT '',

  tolerance_m       DOUBLE      NOT NULL,
  saturation_m      DOUBLE      NOT NULL,
  rejection_m       DOUBLE      NOT NULL,
  created_at        TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at        TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP
                                ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_policy (project_id, tolerance_class, ifc_type, category),
  -- The same ordering the client enforces. A saturation below the tolerance
  -- collapses the heat ramp; a rejection below saturation hides the defects the
  -- ramp exists to show.
  CONSTRAINT ck_policy_order CHECK (
    tolerance_m > 0 AND tolerance_m < saturation_m AND saturation_m < rejection_m),
  CONSTRAINT fk_policy_project FOREIGN KEY (project_id)
    REFERENCES projects (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- ============================================================================
-- BIM models: IFC in, tessellated geometry out
-- ============================================================================

CREATE TABLE bim_models (
  id           BINARY(16)   NOT NULL,
  project_id   BINARY(16)   NOT NULL,
  name         VARCHAR(200) NOT NULL,
  discipline   VARCHAR(64)  NULL,   -- 'Architectural', 'Structural', 'MEP'
  created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                            ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_models_project (project_id),
  CONSTRAINT fk_models_project FOREIGN KEY (project_id)
    REFERENCES projects (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- One import of one IFC file.
--
-- Versioning is not optional. A deviation is a statement about a specific
-- revision of the design, and a model that is re-issued mid-project turns every
-- earlier finding into an unanswerable question unless the revision travels with
-- it. Findings reference model_version_id, never bim_model_id.
CREATE TABLE model_versions (
  id                BINARY(16)   NOT NULL,
  bim_model_id      BINARY(16)   NOT NULL,
  revision          VARCHAR(64)  NOT NULL,

  source_filename   VARCHAR(512) NULL,
  -- 'IFC4', 'IFC2X3', 'IFC4X3_ADD2'. Recorded because property set names and
  -- entity types differ between them and a parser has to know which it has.
  ifc_schema        VARCHAR(32)  NULL,
  -- SHA-256 of the source file. Two uploads of the same bytes are the same
  -- version, whatever the file was called.
  source_sha256     CHAR(64)     NULL,
  source_uri        VARCHAR(1024) NULL,   -- object storage key for the original

  -- Tessellated geometry the device downloads, plus the metadata sidecar that
  -- carries what USDZ cannot.
  usdz_uri          VARCHAR(1024) NULL,
  elements_json_uri VARCHAR(1024) NULL,
  -- Metres per source unit. A Revit export in millimetres imports as 0.001, and
  -- getting this wrong scales every deviation by a factor of a thousand.
  unit_scale        DOUBLE       NOT NULL DEFAULT 1.0,

  element_count     INT UNSIGNED NOT NULL DEFAULT 0,
  triangle_count    BIGINT UNSIGNED NOT NULL DEFAULT 0,

  status            ENUM('uploaded','parsing','tessellating','ready','failed')
                                 NOT NULL DEFAULT 'uploaded',
  failure_reason    TEXT         NULL,

  imported_by       BINARY(16)   NULL,
  imported_at       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                                 ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_version (bim_model_id, revision),
  KEY ix_version_sha (source_sha256),
  KEY ix_version_status (status),
  CONSTRAINT ck_version_scale CHECK (unit_scale > 0),
  CONSTRAINT fk_version_model FOREIGN KEY (bim_model_id)
    REFERENCES bim_models (id) ON DELETE CASCADE,
  CONSTRAINT fk_version_user FOREIGN KEY (imported_by)
    REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- The IFC entity graph, flattened to the parts this system reasons about.
--
-- The original IFC file stays in object storage as the legal record; this table
-- is the queryable projection of it. Storing the file as a blob and re-parsing
-- on every question is the failure mode to avoid — an IFC4 model of a mid-size
-- building is hundreds of megabytes and tens of seconds to parse.
--
-- element_index is the positional index the device and the GPU kernel use. It is
-- assigned at tessellation time and is only meaningful within one version;
-- ifc_guid is the identifier that survives across versions and round-trips to
-- Revit.
CREATE TABLE elements (
  id                BINARY(16)   NOT NULL,
  model_version_id  BINARY(16)   NOT NULL,
  element_index     INT UNSIGNED NOT NULL,

  ifc_guid          CHAR(22)     NULL,
  ifc_type          VARCHAR(64)  NULL,     -- 'IfcColumn'
  category          VARCHAR(128) NULL,     -- 'Structural Columns'
  name              VARCHAR(255) NULL,
  mark              VARCHAR(128) NULL,     -- 'C-12'
  level_name        VARCHAR(128) NULL,
  tolerance_class   ENUM('structural','mep','finishes','unclassified')
                                 NOT NULL DEFAULT 'unclassified',

  -- Model-space bounding box, for spatial filtering and for placing a finding
  -- without loading geometry.
  bbox_min_x        DOUBLE       NULL,
  bbox_min_y        DOUBLE       NULL,
  bbox_min_z        DOUBLE       NULL,
  bbox_max_x        DOUBLE       NULL,
  bbox_max_y        DOUBLE       NULL,
  bbox_max_z        DOUBLE       NULL,
  -- Design surface area, m^2. The denominator of every coverage figure.
  surface_area_m2   DOUBLE       NULL,

  -- Everything the exporter carried that this schema has no column for.
  properties        JSON         NULL,

  created_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_element_index (model_version_id, element_index),
  -- Not UNIQUE on guid: a badly configured export can repeat one, and rejecting
  -- the whole import over that helps nobody. Duplicates are reported instead.
  KEY ix_element_guid (model_version_id, ifc_guid),
  KEY ix_element_type (model_version_id, ifc_type),
  KEY ix_element_level (model_version_id, level_name),
  KEY ix_element_mark (model_version_id, mark),
  CONSTRAINT fk_element_version FOREIGN KEY (model_version_id)
    REFERENCES model_versions (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- Indexed property search over IFC property sets.
--
-- The JSON column on `elements` answers "show me this element's properties".
-- This answers "show me every element where Pset_WallCommon.FireRating = 60",
-- which a JSON scan across a million rows will not do at interactive speed.
-- Populated at import for the property sets a project declares interesting.
CREATE TABLE element_properties (
  id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  element_id        BINARY(16)   NOT NULL,
  model_version_id  BINARY(16)   NOT NULL,
  pset_name         VARCHAR(128) NOT NULL,
  property_name     VARCHAR(128) NOT NULL,
  value_text        VARCHAR(512) NULL,
  -- Parsed numeric form where the value is one, so ranges can be queried.
  value_number      DOUBLE       NULL,
  unit              VARCHAR(32)  NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_element_property (element_id, pset_name, property_name),
  KEY ix_property_lookup (model_version_id, pset_name, property_name, value_text(64)),
  KEY ix_property_number (model_version_id, property_name, value_number),
  CONSTRAINT fk_property_element FOREIGN KEY (element_id)
    REFERENCES elements (id) ON DELETE CASCADE,
  CONSTRAINT fk_property_version FOREIGN KEY (model_version_id)
    REFERENCES model_versions (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- ============================================================================
-- Field capture
-- ============================================================================

CREATE TABLE scan_sessions (
  id                BINARY(16)   NOT NULL,
  project_id        BINARY(16)   NOT NULL,
  model_version_id  BINARY(16)   NULL,   -- NULL for a scan taken with no model
  operator_id       BINARY(16)   NULL,

  name              VARCHAR(200) NULL,
  -- Evidence chain. Which phone took this matters: LiDAR range and noise differ
  -- measurably across generations, and a disputed finding will be argued on it.
  device_model      VARCHAR(64)  NULL,   -- 'iPhone15,3'
  os_version        VARCHAR(32)  NULL,
  app_version       VARCHAR(32)  NULL,

  started_at        DATETIME(3)  NOT NULL,
  ended_at          DATETIME(3)  NULL,

  -- Capture settings in force, so a scan can be re-filtered on the same terms.
  min_depth_confidence TINYINT UNSIGNED NOT NULL DEFAULT 1,
  voxel_size_m      DOUBLE       NOT NULL DEFAULT 0.05,
  scan_point_count  INT UNSIGNED NOT NULL DEFAULT 0,
  mesh_anchor_count INT UNSIGNED NOT NULL DEFAULT 0,

  status            ENUM('capturing','complete','uploading','uploaded','failed')
                                 NOT NULL DEFAULT 'capturing',
  deleted_at        TIMESTAMP    NULL,
  created_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                                 ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_session_project (project_id, started_at),
  KEY ix_session_version (model_version_id),
  KEY ix_session_operator (operator_id),
  CONSTRAINT fk_session_project FOREIGN KEY (project_id)
    REFERENCES projects (id) ON DELETE CASCADE,
  CONSTRAINT fk_session_version FOREIGN KEY (model_version_id)
    REFERENCES model_versions (id) ON DELETE RESTRICT,
  CONSTRAINT fk_session_operator FOREIGN KEY (operator_id)
    REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- The transform every finding in a session is expressed against.
--
-- Kept as its own table rather than columns on the session because a session can
-- legitimately be re-registered: drift is corrected mid-walk, and a scan can be
-- re-aligned after the fact against a corrected model. Each is a row, and a
-- finding points at the one that was current when it was taken.
CREATE TABLE registrations (
  id                BINARY(16)   NOT NULL,
  scan_session_id   BINARY(16)   NOT NULL,
  sequence_no       INT UNSIGNED NOT NULL,   -- 1, 2, 3... within the session

  method            ENUM('manual','control_points','icp','control_points_then_icp')
                                 NOT NULL,
  -- World -> model, row-major, 16 doubles. JSON rather than 16 columns: it is
  -- never queried by component, only read back whole.
  world_to_model    JSON         NOT NULL,
  applied_scale     DOUBLE       NOT NULL DEFAULT 1.0,

  rms_error_m       DOUBLE       NULL,
  inlier_ratio      DOUBLE       NULL,
  degrees_of_freedom ENUM('full','gravity_constrained','translation_only') NULL,
  -- Warnings the fit raised, verbatim. Part of the evidence: "aligned from two
  -- targets 0.8 m apart" is a materially weaker claim than "aligned from five".
  warnings          JSON         NULL,

  established_at    DATETIME(3)  NOT NULL,
  created_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_registration_seq (scan_session_id, sequence_no),
  CONSTRAINT ck_registration_scale CHECK (applied_scale > 0),
  CONSTRAINT fk_registration_session FOREIGN KEY (scan_session_id)
    REFERENCES scan_sessions (id) ON DELETE CASCADE
) ENGINE = InnoDB;


CREATE TABLE control_points (
  id              BINARY(16)   NOT NULL,
  registration_id BINARY(16)   NOT NULL,
  label           VARCHAR(128) NULL,

  world_x         DOUBLE       NOT NULL,
  world_y         DOUBLE       NOT NULL,
  world_z         DOUBLE       NOT NULL,
  model_x         DOUBLE       NOT NULL,
  model_y         DOUBLE       NOT NULL,
  model_z         DOUBLE       NOT NULL,
  element_id      BINARY(16)   NULL,     -- element the model point was picked on
  residual_m      DOUBLE       NULL,

  created_at      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_control_registration (registration_id),
  CONSTRAINT fk_control_registration FOREIGN KEY (registration_id)
    REFERENCES registrations (id) ON DELETE CASCADE,
  CONSTRAINT fk_control_element FOREIGN KEY (element_id)
    REFERENCES elements (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- How far the world frame moved during the session, and what was done about it.
-- Uploaded because it bounds the accuracy of everything else: a session with
-- three 40 mm corrections in it is not the same evidence as one with none.
CREATE TABLE drift_samples (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  scan_session_id BINARY(16)  NOT NULL,
  measured_at     DATETIME(3) NOT NULL,
  displacement_m  DOUBLE      NOT NULL,
  rms_error_m     DOUBLE      NULL,
  corrected       TINYINT(1)  NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY ix_drift_session (scan_session_id, measured_at),
  CONSTRAINT fk_drift_session FOREIGN KEY (scan_session_id)
    REFERENCES scan_sessions (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- Captured geometry lives in object storage; this row is the index entry.
-- Point clouds do not belong in MySQL — a warehouse bay is tens of megabytes of
-- float triples and the database would never read them, only hand them back.
CREATE TABLE point_clouds (
  id              BINARY(16)   NOT NULL,
  scan_session_id BINARY(16)   NOT NULL,
  format          ENUM('ply','e57','las','laz') NOT NULL DEFAULT 'ply',
  storage_uri     VARCHAR(1024) NOT NULL,
  point_count     INT UNSIGNED NOT NULL DEFAULT 0,
  -- Coordinate frame the file is written in. 'model' means the registration was
  -- already applied; 'world' means it was not and the file is only meaningful
  -- alongside its registration row.
  coordinate_frame ENUM('model','world') NOT NULL DEFAULT 'model',
  registration_id BINARY(16)   NULL,
  byte_size       BIGINT UNSIGNED NOT NULL DEFAULT 0,
  sha256          CHAR(64)     NULL,
  created_at      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_cloud_session (scan_session_id),
  CONSTRAINT fk_cloud_session FOREIGN KEY (scan_session_id)
    REFERENCES scan_sessions (id) ON DELETE CASCADE,
  CONSTRAINT fk_cloud_registration FOREIGN KEY (registration_id)
    REFERENCES registrations (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- ============================================================================
-- Deviation results
-- ============================================================================

-- One row per element per session: the verdict.
--
-- Note that `status` has four values, not two. An element nobody scanned is
-- recorded as 'unverified' rather than omitted, because a missing row reads as a
-- passing one — the single most dangerous way this system could be wrong. The
-- reporting view below counts them explicitly for the same reason.
CREATE TABLE element_inspections (
  id                BINARY(16)   NOT NULL,
  scan_session_id   BINARY(16)   NOT NULL,
  element_id        BINARY(16)   NOT NULL,
  registration_id   BINARY(16)   NULL,

  status            ENUM('pass','fail','insufficient_data','unverified') NOT NULL,
  tolerance_m       DOUBLE       NOT NULL,

  sample_count      INT UNSIGNED NOT NULL DEFAULT 0,
  in_tolerance_count INT UNSIGNED NOT NULL DEFAULT 0,
  -- Mean of |signed distance|. "How far out is it, ignoring direction."
  mean_abs_m        DOUBLE       NULL,
  -- Mean of the signed distance. Positive is proud of the design surface.
  -- Kept apart from mean_abs_m on purpose: a wall bowing 10 mm in and 10 mm out
  -- averages to zero signed and 10 mm absolute, and both are true.
  mean_signed_m     DOUBLE       NULL,
  max_abs_m         DOUBLE       NULL,
  -- Mean per-axis offset in model space. The dX/dY/dZ an inspector shims to.
  mean_dx_m         DOUBLE       NULL,
  mean_dy_m         DOUBLE       NULL,
  mean_dz_m         DOUBLE       NULL,

  -- Worst sample, model space, for walking back to it.
  worst_x           DOUBLE       NULL,
  worst_y           DOUBLE       NULL,
  worst_z           DOUBLE       NULL,
  worst_signed_m    DOUBLE       NULL,

  -- Fraction of the element's design surface the scan reached, 0..1.
  coverage          DOUBLE       NULL,

  computed_at       DATETIME(3)  NOT NULL,
  -- 'device' for the live on-site pass, 'server' for the authoritative recompute
  -- over the full cloud. Both are kept: the device figure is what the inspector
  -- acted on, the server figure is what the report is signed against.
  computed_by       ENUM('device','server') NOT NULL DEFAULT 'device',
  created_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                                 ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_inspection (scan_session_id, element_id, computed_by),
  KEY ix_inspection_status (scan_session_id, status),
  KEY ix_inspection_element (element_id),
  KEY ix_inspection_worst (scan_session_id, max_abs_m DESC),
  CONSTRAINT ck_inspection_coverage CHECK (coverage IS NULL
    OR (coverage >= 0 AND coverage <= 1)),
  CONSTRAINT ck_inspection_samples CHECK (in_tolerance_count <= sample_count),
  CONSTRAINT fk_inspection_session FOREIGN KEY (scan_session_id)
    REFERENCES scan_sessions (id) ON DELETE CASCADE,
  CONSTRAINT fk_inspection_element FOREIGN KEY (element_id)
    REFERENCES elements (id) ON DELETE CASCADE,
  CONSTRAINT fk_inspection_registration FOREIGN KEY (registration_id)
    REFERENCES registrations (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- Individual defects an inspector chose to record, as distinct from the
-- statistical roll-up above. These are what a defect tracker consumes.
CREATE TABLE deviation_findings (
  id                BINARY(16)   NOT NULL,
  scan_session_id   BINARY(16)   NOT NULL,
  element_id        BINARY(16)   NULL,     -- NULL when the model had no metadata
  registration_id   BINARY(16)   NULL,

  model_x           DOUBLE       NOT NULL,
  model_y           DOUBLE       NOT NULL,
  model_z           DOUBLE       NOT NULL,
  -- World coordinates too. The model position is the one that means something
  -- across sessions; the world one is what the phone can navigate back to
  -- during the session that recorded it.
  world_x           DOUBLE       NULL,
  world_y           DOUBLE       NULL,
  world_z           DOUBLE       NULL,

  signed_deviation_m DOUBLE      NOT NULL,
  direction         ENUM('proud','recessed') AS (
                      IF(signed_deviation_m >= 0, 'proud', 'recessed')) STORED,
  tolerance_m       DOUBLE       NOT NULL,

  severity          ENUM('info','minor','major','critical')
                                 NOT NULL DEFAULT 'minor',
  workflow_status   ENUM('open','acknowledged','in_progress','resolved','rejected')
                                 NOT NULL DEFAULT 'open',
  note              TEXT         NULL,

  recorded_at       DATETIME(3)  NOT NULL,
  recorded_by       BINARY(16)   NULL,
  resolved_at       DATETIME(3)  NULL,
  deleted_at        TIMESTAMP    NULL,
  created_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                                 ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_finding_session (scan_session_id, recorded_at),
  KEY ix_finding_element (element_id),
  KEY ix_finding_status (workflow_status, severity),
  CONSTRAINT fk_finding_session FOREIGN KEY (scan_session_id)
    REFERENCES scan_sessions (id) ON DELETE CASCADE,
  CONSTRAINT fk_finding_element FOREIGN KEY (element_id)
    REFERENCES elements (id) ON DELETE SET NULL,
  CONSTRAINT fk_finding_registration FOREIGN KEY (registration_id)
    REFERENCES registrations (id) ON DELETE SET NULL,
  CONSTRAINT fk_finding_user FOREIGN KEY (recorded_by)
    REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


CREATE TABLE coverage_reports (
  id                BINARY(16)  NOT NULL,
  scan_session_id   BINARY(16)  NOT NULL,
  registration_id   BINARY(16)  NULL,
  -- Sample spacing, metres. The resolution the number is good to: a coverage
  -- figure without it is not comparable with one taken at a different setting.
  sample_spacing_m  DOUBLE      NOT NULL,
  search_radius_m   DOUBLE      NOT NULL,
  covered_area_m2   DOUBLE      NOT NULL,
  total_area_m2     DOUBLE      NOT NULL,
  computed_at       DATETIME(3) NOT NULL,
  computed_by       ENUM('device','server') NOT NULL DEFAULT 'device',
  created_at        TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_coverage (scan_session_id, computed_by),
  CONSTRAINT ck_coverage_area CHECK (covered_area_m2 <= total_area_m2 * 1.0001),
  CONSTRAINT fk_coverage_session FOREIGN KEY (scan_session_id)
    REFERENCES scan_sessions (id) ON DELETE CASCADE,
  CONSTRAINT fk_coverage_registration FOREIGN KEY (registration_id)
    REFERENCES registrations (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- ============================================================================
-- Redline markups — BCF-shaped
-- ============================================================================

-- Modelled on BCF 2.1/3.0 rather than on a bespoke shape, so a markup can be
-- exported to Navisworks, Solibri or Revit without a translation layer and
-- without losing the camera. topic_guid is the BCF GUID and is what an external
-- tool will use to recognise the same issue on a later round trip.
CREATE TABLE markups (
  id                BINARY(16)   NOT NULL,
  project_id        BINARY(16)   NOT NULL,
  scan_session_id   BINARY(16)   NULL,
  model_version_id  BINARY(16)   NULL,
  topic_guid        CHAR(36)     NOT NULL,

  title             VARCHAR(255) NOT NULL,
  description       TEXT         NULL,
  topic_type        VARCHAR(64)  NULL,    -- BCF: 'Issue', 'Clash', 'Request'
  topic_status      VARCHAR(64)  NOT NULL DEFAULT 'Open',
  priority          VARCHAR(64)  NULL,
  stage             VARCHAR(64)  NULL,
  due_date          DATE         NULL,

  assigned_to       BINARY(16)   NULL,
  created_by        BINARY(16)   NULL,
  deleted_at        TIMESTAMP    NULL,
  created_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                                 ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_markup_guid (topic_guid),
  KEY ix_markup_project (project_id, topic_status),
  KEY ix_markup_session (scan_session_id),
  CONSTRAINT fk_markup_project FOREIGN KEY (project_id)
    REFERENCES projects (id) ON DELETE CASCADE,
  CONSTRAINT fk_markup_session FOREIGN KEY (scan_session_id)
    REFERENCES scan_sessions (id) ON DELETE SET NULL,
  CONSTRAINT fk_markup_version FOREIGN KEY (model_version_id)
    REFERENCES model_versions (id) ON DELETE SET NULL,
  CONSTRAINT fk_markup_assignee FOREIGN KEY (assigned_to)
    REFERENCES users (id) ON DELETE SET NULL,
  CONSTRAINT fk_markup_author FOREIGN KEY (created_by)
    REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- The camera and visibility state a markup was authored from. Without it a
-- redline is a note about a building; with it, it is a note about a place.
CREATE TABLE markup_viewpoints (
  id            BINARY(16)  NOT NULL,
  markup_id     BINARY(16)  NOT NULL,
  guid          CHAR(36)    NOT NULL,

  camera_type   ENUM('perspective','orthogonal') NOT NULL DEFAULT 'perspective',
  camera_x      DOUBLE      NOT NULL,
  camera_y      DOUBLE      NOT NULL,
  camera_z      DOUBLE      NOT NULL,
  direction_x   DOUBLE      NOT NULL,
  direction_y   DOUBLE      NOT NULL,
  direction_z   DOUBLE      NOT NULL,
  up_x          DOUBLE      NOT NULL,
  up_y          DOUBLE      NOT NULL,
  up_z          DOUBLE      NOT NULL,
  field_of_view DOUBLE      NULL,
  view_to_world_scale DOUBLE NULL,   -- orthogonal cameras only

  -- BCF component selection and visibility, plus any 2D annotation strokes the
  -- operator drew over the camera image.
  components    JSON        NULL,
  annotations   JSON        NULL,
  snapshot_uri  VARCHAR(1024) NULL,

  created_at    TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_viewpoint_guid (guid),
  KEY ix_viewpoint_markup (markup_id),
  CONSTRAINT fk_viewpoint_markup FOREIGN KEY (markup_id)
    REFERENCES markups (id) ON DELETE CASCADE
) ENGINE = InnoDB;


CREATE TABLE markup_comments (
  id            BINARY(16)  NOT NULL,
  markup_id     BINARY(16)  NOT NULL,
  viewpoint_id  BINARY(16)  NULL,
  guid          CHAR(36)    NOT NULL,
  body          TEXT        NOT NULL,
  author_id     BINARY(16)  NULL,
  created_at    TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP
                            ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_comment_guid (guid),
  KEY ix_comment_markup (markup_id, created_at),
  CONSTRAINT fk_comment_markup FOREIGN KEY (markup_id)
    REFERENCES markups (id) ON DELETE CASCADE,
  CONSTRAINT fk_comment_viewpoint FOREIGN KEY (viewpoint_id)
    REFERENCES markup_viewpoints (id) ON DELETE SET NULL,
  CONSTRAINT fk_comment_author FOREIGN KEY (author_id)
    REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- Elements a markup is about. BCF carries these as IFC GUIDs, which is what
-- makes an issue survive a model re-issue, so the GUID is stored alongside the
-- resolved row: the element may not exist in a later version, and the issue
-- still has to be readable.
CREATE TABLE markup_elements (
  markup_id   BINARY(16) NOT NULL,
  element_id  BINARY(16) NULL,
  ifc_guid    CHAR(22)   NOT NULL,
  PRIMARY KEY (markup_id, ifc_guid),
  KEY ix_markup_element (element_id),
  CONSTRAINT fk_markupel_markup FOREIGN KEY (markup_id)
    REFERENCES markups (id) ON DELETE CASCADE,
  CONSTRAINT fk_markupel_element FOREIGN KEY (element_id)
    REFERENCES elements (id) ON DELETE SET NULL
) ENGINE = InnoDB;


CREATE TABLE attachments (
  id              BINARY(16)   NOT NULL,
  scan_session_id BINARY(16)   NULL,
  markup_id       BINARY(16)   NULL,
  finding_id      BINARY(16)   NULL,
  kind            ENUM('photo','video','audio','document','snapshot') NOT NULL,
  storage_uri     VARCHAR(1024) NOT NULL,
  mime_type       VARCHAR(128) NULL,
  byte_size       BIGINT UNSIGNED NOT NULL DEFAULT 0,
  sha256          CHAR(64)     NULL,
  captured_at     DATETIME(3)  NULL,
  uploaded_by     BINARY(16)   NULL,
  created_at      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_attachment_session (scan_session_id),
  KEY ix_attachment_markup (markup_id),
  KEY ix_attachment_finding (finding_id),
  CONSTRAINT fk_attachment_session FOREIGN KEY (scan_session_id)
    REFERENCES scan_sessions (id) ON DELETE CASCADE,
  CONSTRAINT fk_attachment_markup FOREIGN KEY (markup_id)
    REFERENCES markups (id) ON DELETE CASCADE,
  CONSTRAINT fk_attachment_finding FOREIGN KEY (finding_id)
    REFERENCES deviation_findings (id) ON DELETE CASCADE
) ENGINE = InnoDB;


-- ============================================================================
-- Sync and audit
-- ============================================================================

-- Idempotency for the offline-first client.
--
-- A phone on a construction site loses connectivity constantly and retries. The
-- client stamps every change with a UUID it generates locally; this table
-- remembers which of those have been applied, so a retry after a response was
-- lost in transit is a no-op rather than a duplicate finding.
--
-- Rows are prunable after the client's retry window — a month is generous.
CREATE TABLE sync_receipts (
  client_change_id BINARY(16)  NOT NULL,
  device_id        VARCHAR(128) NOT NULL,
  entity_type      VARCHAR(64) NOT NULL,
  entity_id        BINARY(16)  NULL,
  applied_at       TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (client_change_id),
  KEY ix_receipt_device (device_id, applied_at)
) ENGINE = InnoDB;


CREATE TABLE audit_log (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  actor_id     BINARY(16)   NULL,
  entity_type  VARCHAR(64)  NOT NULL,
  entity_id    BINARY(16)   NULL,
  action       VARCHAR(64)  NOT NULL,   -- 'create', 'update', 'sign_off'
  detail       JSON         NULL,
  occurred_at  TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  KEY ix_audit_entity (entity_type, entity_id, occurred_at),
  KEY ix_audit_actor (actor_id, occurred_at),
  CONSTRAINT fk_audit_actor FOREIGN KEY (actor_id)
    REFERENCES users (id) ON DELETE SET NULL
) ENGINE = InnoDB;


-- ============================================================================
-- Reporting views
-- ============================================================================

-- The front page of a session report.
--
-- pass_rate and verified_fraction are deliberately presented together and never
-- separately. A 100% pass rate over 12% of a building is not a passing building,
-- and a report that shows only the first number invites exactly that reading.
CREATE OR REPLACE VIEW v_session_summary AS
SELECT
  s.id                                                    AS scan_session_id,
  s.project_id,
  s.model_version_id,
  s.started_at,
  s.ended_at,
  COUNT(*)                                                AS element_count,
  SUM(i.status = 'pass')                                  AS pass_count,
  SUM(i.status = 'fail')                                  AS fail_count,
  SUM(i.status = 'insufficient_data')                     AS insufficient_count,
  SUM(i.status = 'unverified')                            AS unverified_count,
  SUM(i.status IN ('pass','fail'))                        AS measured_count,
  -- NULLIF keeps a session with nothing measured out of a divide by zero, and
  -- returns NULL rather than a misleading 0% or 100%.
  SUM(i.status = 'pass') / NULLIF(SUM(i.status IN ('pass','fail')), 0)
                                                          AS pass_rate,
  SUM(i.status IN ('pass','fail')) / NULLIF(COUNT(*), 0)  AS verified_fraction,
  MAX(i.max_abs_m)                                        AS worst_deviation_m
FROM scan_sessions s
JOIN element_inspections i
  ON i.scan_session_id = s.id
 AND i.computed_by = 'server'
WHERE s.deleted_at IS NULL
GROUP BY s.id, s.project_id, s.model_version_id, s.started_at, s.ended_at;


-- Worst findings per session, joined to the identity a person can act on.
CREATE OR REPLACE VIEW v_element_findings AS
SELECT
  i.scan_session_id,
  e.ifc_guid,
  e.ifc_type,
  e.category,
  e.level_name,
  COALESCE(NULLIF(e.mark, ''), e.name)  AS label,
  i.status,
  i.tolerance_m,
  i.max_abs_m,
  i.mean_signed_m,
  i.mean_dx_m,
  i.mean_dy_m,
  i.mean_dz_m,
  i.coverage,
  i.sample_count
FROM element_inspections i
JOIN elements e ON e.id = i.element_id
WHERE i.computed_by = 'server';


-- Deviation history for one element across every session it appears in, keyed
-- by IFC GUID so it survives model re-issues. This is the M13 trend feed.
CREATE OR REPLACE VIEW v_element_history AS
SELECT
  e.ifc_guid,
  s.project_id,
  s.id           AS scan_session_id,
  s.started_at,
  mv.revision    AS model_revision,
  i.status,
  i.max_abs_m,
  i.mean_signed_m,
  i.coverage
FROM element_inspections i
JOIN elements e        ON e.id = i.element_id
JOIN model_versions mv ON mv.id = e.model_version_id
JOIN scan_sessions s   ON s.id = i.scan_session_id
WHERE e.ifc_guid IS NOT NULL
  AND s.deleted_at IS NULL
  AND i.computed_by = 'server';
