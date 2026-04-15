defmodule Claude do
  @moduledoc """
  Claude Code subprocess/SSH session client. Callers pass claude settings
  and a pre-validated workspace path into `Claude.Session.start_session/2`;
  `Claude` never reads Application env itself.
  """

  use Boundary, deps: [Permissions, Transport], exports: [Session, Usage]
end
