defmodule Web do
  @moduledoc """
  Phoenix endpoint, LiveView dashboard, and JSON observability API.
  Depends on `Core` (domain + orchestrator state) and `Schema` (shared
  types). Never the other way around.
  """

  use Boundary,
    deps: [Core, Schema],
    exports: [
      DashboardLive,
      Endpoint,
      ErrorHTML,
      ErrorJSON,
      HttpServer,
      Layouts,
      ObservabilityApiController,
      Presenter,
      Router,
      StaticAssetController,
      StaticAssets
    ]
end
