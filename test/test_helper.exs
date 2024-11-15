task =
  Task.async(fn ->
    {:ok, redix} = Redix.start_link("redis://localhost:6379")
    {:ok, "PONG"} == Redix.command(redix, ["PING"])
  end)

redis_available? = Task.await(task)

exclude =
  if redis_available? do
    []
  else
    Mix.shell().error("""
    To enable Redis tests, start the local container with the following command:

        docker compose up -d redis
    """)

    [:redis]
  end

ExUnit.start(exclude: exclude)
