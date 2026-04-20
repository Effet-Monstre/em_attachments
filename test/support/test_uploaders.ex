defmodule EmAttachments.Test.BasicUploader do
  use EmAttachments.Uploader,
    plugins: [
      mime: EmAttachments.Plugins.Mime
    ]

  validates mime: [type: ~w(image/png image/jpeg), extension: ~w(png jpg jpeg)]
end

defmodule EmAttachments.Test.DerivativeUploader do
  use EmAttachments.Uploader,
    plugins: [
      mime: EmAttachments.Plugins.Mime,
      derivatives: EmAttachments.Plugins.Derivatives
    ]

  def cast(:derivatives, file) do
    content = File.read!(file.path)
    %{copy: content}
  end
end

defmodule EmAttachments.Test.NoPluginUploader do
  use EmAttachments.Uploader
end
