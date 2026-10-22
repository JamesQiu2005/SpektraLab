// Sharing diagnostics is explicit. The default bundle has no paths, filenames,
// command arguments, stderr or recipe metadata; the in-app view can show them.
export function diagnosticReport(app: { version?: string; os?: string } | null, hello: unknown, diagnostics: unknown, includePaths: boolean, memory?: unknown) {
  const h = hello as { host_version?: string; build_info?: string; backend?: { api?: string; device_name?: string }; methods?: string[]; view_formats?: string[] } | null;
  const d = diagnostics as { state?: { phase?: string }; launch?: { origin?: string; mock?: boolean } } | null;
  return { generated_at: new Date().toISOString(), app: { version: app?.version, os: app?.os },
    engine: { host_version: h?.host_version, build_info: h?.build_info, backend: { api: h?.backend?.api, device_name: h?.backend?.device_name },
      view_formats: h?.view_formats, methods: h?.methods },
    engine_memory_ledger: memory,
    host: includePaths ? diagnostics : { phase: d?.state?.phase, launch_origin: d?.launch?.origin, mock: d?.launch?.mock },
    includes_paths_and_logs: includePaths };
}
