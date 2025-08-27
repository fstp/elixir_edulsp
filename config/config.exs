import Config

config :logger,
  handle_otp_reports: true,
  handle_sasl_reports: true,
  # backends: [:console, {LoggerFileBackend, :file_log}],
  backends: [{LoggerFileBackend, :file_log}],
  level: :info

config :logger, :file_log,
  path: "/home/ebljohn/github/elixir_edulsp/logs/elixir_edulsp.log",
  level: :info
