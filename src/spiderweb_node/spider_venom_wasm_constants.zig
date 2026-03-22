pub const abi_version: u32 = 1;
pub const abi_version_export_name = "spider_venom_abi_version";
pub const alloc_export_name = "spider_venom_alloc";
pub const invoke_json_export_name = "spider_venom_invoke_json";

pub const import_module_name = "spider_host_v1";
pub const capabilities_export_name = "spider_host_capabilities";
pub const now_ms_export_name = "spider_host_now_ms";
pub const log_export_name = "spider_host_log";
pub const random_fill_export_name = "spider_host_random_fill";
pub const emit_event_json_export_name = "spider_host_emit_event_json";

pub const capability_bit_log: u6 = 0;
pub const capability_bit_clock: u6 = 1;
pub const capability_bit_random: u6 = 2;
pub const capability_bit_emit_event: u6 = 3;
