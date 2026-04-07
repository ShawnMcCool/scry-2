defmodule Scry2Web.Plugs.CardImageTest do
  use Scry2Web.ConnCase, async: true

  setup do
    cache_dir =
      Path.join(System.tmp_dir!(), "scry2_plug_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(cache_dir)
    File.write!(Path.join(cache_dir, "91001.jpg"), "fake jpeg data")
    on_exit(fn -> File.rm_rf!(cache_dir) end)
    %{cache_dir: cache_dir}
  end

  describe "GET /images/cards/:arena_id.jpg" do
    test "serves a cached image with correct headers", %{conn: conn, cache_dir: cache_dir} do
      conn =
        conn
        |> assign(:image_cache_dir, cache_dir)
        |> Map.put(:path_params, %{"arena_id" => "91001.jpg"})
        |> Scry2Web.Plugs.CardImage.call([])

      assert conn.status == 200
      assert conn.resp_body == "fake jpeg data"
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end

    test "returns 404 for missing image", %{conn: conn, cache_dir: cache_dir} do
      conn =
        conn
        |> assign(:image_cache_dir, cache_dir)
        |> Map.put(:path_params, %{"arena_id" => "99999.jpg"})
        |> Scry2Web.Plugs.CardImage.call([])

      assert conn.status == 404
    end

    test "returns 404 for non-integer arena_id", %{conn: conn, cache_dir: cache_dir} do
      conn =
        conn
        |> assign(:image_cache_dir, cache_dir)
        |> Map.put(:path_params, %{"arena_id" => "notanumber.jpg"})
        |> Scry2Web.Plugs.CardImage.call([])

      assert conn.status == 404
    end
  end
end
