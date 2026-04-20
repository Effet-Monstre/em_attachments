defmodule EmAttachments.AsyncDispatcher do
  @moduledoc """
  Behaviour for custom background job dispatchers.

  Implement this module and set it in config to enable background processing:

      config :em_attachments, :config,
        async_dispatcher: MyApp.AttachmentsDispatcher

  The dispatcher receives a job map and is responsible for:
  1. Persisting the job (e.g. Oban)
  2. When the job runs: fetching the file from the DB, calling
     `plugin_mod.after_upload_async/4`, and persisting the returned metadata fragment.
  """

  @callback enqueue(%{
              uploader: module(),
              file_id: String.t(),
              plugin_key: atom(),
              plugin_mod: module(),
              plugin_opts: keyword()
            }) :: :ok | {:error, term()}
end
