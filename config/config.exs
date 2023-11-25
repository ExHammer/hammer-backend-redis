import Config

if config_env() == :test do
  config :hammer, backend: Hammer.Backend.Redis
end
