defmodule Transport do
  @moduledoc """
  Low-level communication primitives. Today: `Transport.SSH`. Future
  home for other transports (gRPC, MQTT, etc.). Reads only its own
  config from Application env; no in-app deps.
  """

  use Boundary, deps: [Utils], exports: [SSH]
end
