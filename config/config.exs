import Config

if config_env() == :test do
  config :jev,
    api_key: "test-key",
    req_options: [plug: {Req.Test, Jev.HTTP}, retry_delay: 0, retry_log_level: false]
end
