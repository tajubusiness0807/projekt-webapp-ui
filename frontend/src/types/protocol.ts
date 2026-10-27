// Typen des WebSocket-/REST-Protokolls. Spiegeln die Backend-Modelle (docs/communication-protocol.md).

export type ProfileName = 'eco' | 'normal' | 'sport' | 'custom';
export type DriveModeName = 'awd' | 'fwd' | 'rwd' | 'custom';
export type Direction = 'forward' | 'reverse';
export type MeasurementStatus = 'valid' | 'stale' | 'unavailable' | 'simulated';
export type VehicleStateName = 'initializing' | 'locked' | 'armed' | 'fault' | 'emergency_stop';
export type BrakeStateName = 'inactive' | 'coasting' | 'requested' | 'confirmed' | 'unsupported';
export type Role = 'driver' | 'admin';
export type Severity = 'info' | 'warning' | 'critical';
export type InputSource = 'pedals' | 'joystick' | 'tilt' | 'keyboard' | 'none';

export interface Measurement {
  value: number | null;
  status: MeasurementStatus;
  age_ms: number | null;
  unit: string;
}

export interface DriveProfileSettings {
  max_throttle_percent: number;
  accel_ramp_percent_per_s: number;
  brake_strength_percent: number;
  steering_sensitivity_percent: number;
  deadzone_percent: number;
  max_speed_kmh: number;
  front_power_limit_percent: number;
  rear_power_limit_percent: number;
  left_limit_percent: number;
  right_limit_percent: number;
}

export interface ControllerSettings {
  id: 'A' | 'B';
  label: string;
  axle: 'front' | 'rear';
  port: string;
  baudrate: number;
  feedback_with_odometry: boolean;
  speed_coefficient: number;
  steer_coefficient: number;
  max_command: number;
  invert_left_command: boolean;
  invert_right_command: boolean;
  invert_left_feedback: boolean;
  invert_right_feedback: boolean;
  swap_sides: boolean;
}

export interface VehicleSettings {
  schema_version: number;
  general: { default_profile: ProfileName; default_drive_mode: DriveModeName };
  profiles: Record<ProfileName, DriveProfileSettings>;
  power_split: { awd_front_percent: number; custom_front_percent: number };
  tilt: {
    full_lock_angle_deg: number;
    max_steer_percent: number;
    deadzone_deg: number;
    smoothing: number;
    invert: boolean;
    pitch_function: 'off' | 'throttle';
    pitch_full_angle_deg: number;
    pitch_deadzone_deg: number;
  };
  ui: {
    speedometer_max_kmh: number;
    rpm_gauge_max: number;
    keyboard_throttle_percent: number;
    pedal_mode: 'proportional' | 'full';
    haptic_feedback: boolean;
    show_steering_slider: boolean;
  };
  battery: {
    cells_series: number;
    cell_full_v: number;
    cell_warning_v: number;
    cell_critical_v: number;
    cell_empty_v: number;
    protection_enabled: boolean;
  };
  temperature: {
    controller_warning_c: number;
    controller_critical_c: number;
    motor_warning_c: number;
    motor_critical_c: number;
  };
  safety: {
    command_timeout_ms: number;
    connection_timeout_ms: number;
    controller_timeout_ms: number;
    telemetry_stale_ms: number;
    max_command_age_ms: number;
    max_command_rate_hz: number;
    absolute_max_speed_kmh: number;
    absolute_max_throttle_percent: number;
    absolute_max_accel_ramp_percent_per_s: number;
    reverse_max_speed_kmh: number;
    reverse_max_throttle_percent: number;
    standstill_speed_kmh: number;
    loop_stall_ms: number;
    max_sessions: number;
  };
  hardware: {
    mode: 'simulation' | 'hardware';
    controller_model: string;
    firmware: 'unknown' | 'hoverboard-firmware-hack-foc';
    firmware_version: string;
    firmware_variant_usart: boolean;
    firmware_control_mode: 'unknown' | 'voltage' | 'speed' | 'torque';
    protocol_verified: boolean;
    signal_levels_verified: boolean;
    wiring_verified: boolean;
    independent_axle_control: boolean;
    wheel_diameter_m: number;
    wheel_diameter_verified: boolean;
    temperature_calibrated: boolean;
    wheels_lifted_test_passed: boolean;
    brake_method: 'none' | 'voltage_mode_zero' | 'counter_torque';
    brake_verified: boolean;
    controllers: ControllerSettings[];
  };
  telemetry: { broadcast_hz: number; control_loop_hz: number };
}

export interface EffectiveProfile {
  max_throttle_percent: number;
  accel_ramp_percent_per_s: number;
  brake_strength_percent: number;
  steering_sensitivity_percent: number;
  deadzone_percent: number;
  max_speed_kmh: number;
  limited: Record<string, string>;
}

export interface Availability {
  available: boolean;
  reason: string | null;
}

export interface ReadinessItem {
  key: string;
  ok: boolean;
  label: string;
  detail: string;
}

export interface Capabilities {
  mode: 'simulation' | 'hardware';
  drive_modes: Record<DriveModeName, Availability>;
  axle_distribution: Availability;
  brake: { available: boolean; method: string; note: string };
  measurements: {
    speed: boolean;
    voltage: boolean;
    controller_temperature: boolean;
    motor_temperature: boolean;
    electrical_power: boolean;
  };
  commissioning: boolean;
  hardware_init_error: string | null;
  readiness: ReadinessItem[];
  restart_required: boolean;
  simulation_faults: Record<string, string>;
  battery_limits: { full_v: number; warning_v: number; critical_v: number; empty_v: number };
  effective_profiles: Record<ProfileName, EffectiveProfile>;
  wheel_diameter_m: number | null;
}

export interface FaultDefinition {
  code: string;
  severity: Severity;
  blocking: boolean;
  title: string;
  description: string;
  remedy: string;
}

export interface ActiveFault {
  code: string;
  source: string;
  detail: string;
  since: number;
  active: boolean;
  blocking: boolean;
  severity: Severity;
  title: string;
  count: number;
}

export interface EventEntry {
  id: number;
  ts: number;
  level: Severity;
  code: string;
  category: string;
  message: string;
  details: Record<string, unknown> | null;
}

export interface WheelPair {
  left: number;
  right: number;
}

export interface ControllerTelemetry {
  id: string;
  axle: 'front' | 'rear';
  adapter: string;
  link: 'disconnected' | 'connecting' | 'connected' | 'error' | 'disabled';
  feedback_age_ms: number | null;
  frames_ok: number;
  frames_bad: number;
  commands_sent: number;
  write_errors: number;
  last_error: string | null;
  emergency_stopped: boolean;
  port: string | null;
  capabilities: Record<string, boolean | string>;
  rpm_left: Measurement;
  rpm_right: Measurement;
  voltage: Measurement;
  controller_temp_c: Measurement;
  motor_temp_c: Measurement;
  electrical_power_w: Measurement;
}

export interface SessionInfo {
  id: string;
  role: Role;
  is_owner: boolean;
  owner_present: boolean;
  owner_device: string | null;
  count: number;
  can_takeover: boolean;
}

export interface Telemetry {
  type: 'telemetry';
  seq: number;
  ts: number;
  mode: 'simulation' | 'hardware';
  vehicle: {
    state: VehicleStateName;
    armed: boolean;
    neutral_required: boolean;
    estop: boolean;
    direction: Direction;
    profile: ProfileName;
    drive_mode: DriveModeName;
    brake_state: BrakeStateName;
    brake_support: 'applied' | 'drive_off_only' | null;
    trip_s: number;
    total_drive_s: number;
    restart_required: boolean;
    commissioning: boolean;
    sim_faults: string[];
  };
  measurements: {
    speed_kmh: Measurement;
    motor_rpm: Measurement;
    battery_voltage: Measurement;
    battery_percent: Measurement;
    controller_temp_c: Measurement;
    motor_temp_c: Measurement;
    electrical_power_w: Measurement;
    wifi_signal_dbm: Measurement;
    wifi_quality: 'stark' | 'gut' | 'mittel' | 'schwach' | 'unbekannt';
  };
  control: {
    input: { throttle: number; brake: number; steer: number };
    output: {
      target_throttle: number;
      effective_throttle: number;
      drive_level: number;
      brake_level: number;
      steer: number;
      speed_limit_kmh: number;
      speed_factor: number;
      front: WheelPair;
      rear: WheelPair;
      limited_by: string[];
    };
    split: {
      front_weight: number;
      rear_weight: number;
      front_scale: number;
      rear_scale: number;
      distribution_available: boolean;
    };
    effective_profile: EffectiveProfile;
  };
  controllers: ControllerTelemetry[];
  faults: ActiveFault[];
  system: {
    loop_hz: number | null;
    loop_max_ms: number | null;
    uptime_s: number;
    cpu_temp_c?: number | null;
    load_1m?: number;
    mem_available_mb?: number | null;
    process_rss_mb?: number | null;
    throttled?: string[] | null;
  };
  session: SessionInfo;
}

export interface Welcome {
  type: 'welcome';
  protocol: number;
  version: string;
  session_id: string;
  role: Role;
  mode: 'simulation' | 'hardware';
  server_time: number;
  settings: VehicleSettings;
  settings_version: number;
  capabilities: Capabilities;
  fault_catalog: FaultDefinition[];
  events: EventEntry[];
}

export interface Ack {
  type: 'ack';
  ref_type: string;
  ref_seq: number | null;
  ok: boolean;
  code?: string;
  message?: string;
  version?: number;
  details?: { loc: string; msg: string }[];
}

export type ServerMessage =
  | Welcome
  | Telemetry
  | Ack
  | { type: 'pong'; ts: number; server_ts: number }
  | { type: 'event'; event: EventEntry }
  | { type: 'settings'; version: number; settings: VehicleSettings; capabilities: Capabilities }
  | { type: 'connection'; event: string; message: string }
  | { type: 'error'; code: string; message: string };
