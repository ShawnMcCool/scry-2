defmodule Scry2Web.Plugs.CardImage do
  @moduledoc """
  Serves cached card images from the image cache directory.

  Returns the image with `Cache-Control: immutable` so the browser
  never re-requests it. Card art doesn't change.

  Mounted at `GET /images/cards/:arena_id.jpg` in the router.
  """

  import Plug.Conn

  alias Scry2.Cards.ImageCache
  alias Scry2.Config

  def init(opts), do: opts

  def call(conn, _opts) do
    arena_id_str = conn.path_params["arena_id"] || conn.params["arena_id"]
    # Strip .jpg suffix if present (Phoenix route captures "91001.jpg" as the param)
    arena_id_str = String.replace_suffix(arena_id_str, ".jpg", "")
    cache_dir = conn.assigns[:image_cache_dir] || Config.get(:image_cache_dir)

    with {arena_id, ""} <- Integer.parse(arena_id_str),
         path <- ImageCache.path_for(arena_id, cache_dir),
         true <- File.exists?(path) do
      conn
      |> put_resp_content_type("image/jpeg")
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_file(200, path)
    else
      _ ->
        conn
        |> send_resp(404, "Not found")
    end
  end
end
