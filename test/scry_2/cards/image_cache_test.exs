defmodule Scry2.Cards.ImageCacheTest do
  use Scry2.DataCase, async: true

  alias Scry2.Cards.ImageCache
  alias Scry2.TestFactory

  setup do
    cache_dir =
      Path.join(System.tmp_dir!(), "scry2_test_images_#{System.unique_integer([:positive])}")

    File.mkdir_p!(cache_dir)
    on_exit(fn -> File.rm_rf!(cache_dir) end)
    %{cache_dir: cache_dir}
  end

  describe "url_for/1" do
    test "returns the URL path for an arena_id" do
      assert ImageCache.url_for(91001) == "/images/cards/91001.jpg"
    end
  end

  describe "path_for/3" do
    test "returns the filesystem path for an arena_id", %{cache_dir: cache_dir} do
      path = ImageCache.path_for(91001, :full, cache_dir)
      assert path == Path.join(cache_dir, "91001.jpg")
    end
  end

  describe "ensure_version!/1" do
    test "clears an unversioned cache and stamps the current version", %{cache_dir: cache_dir} do
      # Pre-versioning caches hold art keyed to whatever printing the old
      # lookup resolved — stale once display art became canonical.
      File.write!(Path.join(cache_dir, "91001.jpg"), "stale special art")
      File.write!(Path.join(cache_dir, "91001-art.jpg"), "stale art crop")

      ImageCache.ensure_version!(cache_dir)

      refute File.exists?(Path.join(cache_dir, "91001.jpg"))
      refute File.exists?(Path.join(cache_dir, "91001-art.jpg"))
      assert File.read!(Path.join(cache_dir, "cache-version")) == ImageCache.cache_version()
    end

    test "leaves a current-version cache untouched", %{cache_dir: cache_dir} do
      File.write!(Path.join(cache_dir, "cache-version"), ImageCache.cache_version())
      File.write!(Path.join(cache_dir, "91001.jpg"), "current art")

      ImageCache.ensure_version!(cache_dir)

      assert File.read!(Path.join(cache_dir, "91001.jpg")) == "current art"
    end

    test "creates the marker in a fresh cache dir", %{cache_dir: cache_dir} do
      fresh = Path.join(cache_dir, "fresh")

      ImageCache.ensure_version!(fresh)

      assert File.read!(Path.join(fresh, "cache-version")) == ImageCache.cache_version()
    end
  end

  describe "ensure_cached/2 — deferred version turnover" do
    test "leaves an old-version cache alone while display art is unstamped", %{
      cache_dir: cache_dir
    } do
      # Clearing before synthesis stamps would re-cache literal-printing
      # art from the API fallback under the new version.
      Scry2.Cards.synthesize_card!(%{arena_id: 93_001, name: "Unstamped"})
      File.write!(Path.join(cache_dir, "93001.jpg"), "old art")

      ImageCache.ensure_cached([], cache_dir: cache_dir)

      assert File.read!(Path.join(cache_dir, "93001.jpg")) == "old art"
      refute File.exists?(Path.join(cache_dir, "cache-version"))
    end

    test "turns the cache over on first use once display art is stamped", %{
      cache_dir: cache_dir
    } do
      Scry2.Cards.synthesize_card!(%{
        arena_id: 93_002,
        name: "Stamped",
        image_url: "http://x/basic.jpg"
      })

      File.write!(Path.join(cache_dir, "93001.jpg"), "old art")

      ImageCache.ensure_cached([], cache_dir: cache_dir)

      refute File.exists?(Path.join(cache_dir, "93001.jpg"))
      assert File.read!(Path.join(cache_dir, "cache-version")) == ImageCache.cache_version()
    end
  end

  describe "ensure_cached/2" do
    test "returns immediately for empty list", %{cache_dir: cache_dir} do
      assert {:ok, %{cached: 0, downloaded: 0, failed: 0}} =
               ImageCache.ensure_cached([], cache_dir: cache_dir)
    end

    test "reports already-cached files", %{cache_dir: cache_dir} do
      File.write!(Path.join(cache_dir, "91001.jpg"), "fake jpeg")

      assert {:ok, %{cached: 1, downloaded: 0, failed: 0}} =
               ImageCache.ensure_cached([91001], cache_dir: cache_dir)
    end

    test "downloads image from the stamped display-art URL without hitting the API", %{
      cache_dir: cache_dir
    } do
      Scry2.Cards.synthesize_card!(%{
        arena_id: 91_005,
        name: "DB Card",
        image_url: "http://stub.test/image.jpg"
      })

      Req.Test.stub(ImageCache, fn conn ->
        # Only the CDN download should fire — not the Scryfall API endpoint
        refute conn.request_path =~ "/cards/tst/77",
               "should not hit Scryfall API when image_uris are in DB"

        Plug.Conn.resp(conn, 200, "cdn jpeg data")
      end)

      assert {:ok, %{cached: 0, downloaded: 1, failed: 0}} =
               ImageCache.ensure_cached([91_005],
                 cache_dir: cache_dir,
                 req_options: [plug: {Req.Test, ImageCache}]
               )

      assert File.exists?(Path.join(cache_dir, "91005.jpg"))
    end

    test "downloads missing images from Scryfall via set+collector lookup", %{
      cache_dir: cache_dir
    } do
      TestFactory.create_mtga_card(%{
        arena_id: 91_002,
        name: "Test Card",
        expansion_code: "TST",
        collector_number: "42"
      })

      Req.Test.stub(ImageCache, fn conn ->
        case conn.request_path do
          "/cards/tst/42" ->
            Req.Test.json(conn, %{
              "image_uris" => %{"normal" => "http://stub.test/image.jpg"}
            })

          "/image.jpg" ->
            Plug.Conn.resp(conn, 200, "fake jpeg data")
        end
      end)

      assert {:ok, %{cached: 0, downloaded: 1, failed: 0}} =
               ImageCache.ensure_cached([91_002],
                 cache_dir: cache_dir,
                 req_options: [plug: {Req.Test, ImageCache}]
               )

      assert File.exists?(Path.join(cache_dir, "91002.jpg"))
    end

    test "skips arena_ids with no MtgaCard record", %{cache_dir: cache_dir} do
      assert {:ok, %{cached: 0, downloaded: 0, failed: 1}} =
               ImageCache.ensure_cached([99_999_999], cache_dir: cache_dir)
    end

    test "skips cards with no expansion code", %{cache_dir: cache_dir} do
      TestFactory.create_mtga_card(%{
        arena_id: 91_003,
        name: "No Set",
        expansion_code: "",
        collector_number: ""
      })

      assert {:ok, %{cached: 0, downloaded: 0, failed: 1}} =
               ImageCache.ensure_cached([91_003], cache_dir: cache_dir)
    end

    test "ensure_cached :art downloads art_crop to {id}-art.jpg", %{cache_dir: cache_dir} do
      Scry2.Cards.synthesize_card!(%{
        arena_id: 92_001,
        name: "Art Var",
        image_url: "http://x/n.jpg",
        art_crop_url: "http://x/a.jpg"
      })

      Req.Test.stub(ImageCache, fn conn -> Plug.Conn.send_resp(conn, 200, "ARTBYTES") end)

      assert {:ok, %{downloaded: 1}} =
               ImageCache.ensure_cached([92_001],
                 cache_dir: cache_dir,
                 variant: :art,
                 req_options: [plug: {Req.Test, ImageCache}]
               )

      assert ImageCache.url_for(92_001, :art) == "/images/cards/92001-art.jpg"
      assert ImageCache.cached?(92_001, :art, cache_dir)
      assert File.read!(ImageCache.path_for(92_001, :art, cache_dir)) == "ARTBYTES"
    end

    test "handles mixed cached and uncached", %{cache_dir: cache_dir} do
      File.write!(Path.join(cache_dir, "91001.jpg"), "fake jpeg")

      TestFactory.create_mtga_card(%{
        arena_id: 91_004,
        name: "New Card",
        expansion_code: "TST",
        collector_number: "99"
      })

      Req.Test.stub(ImageCache, fn conn ->
        case conn.request_path do
          "/cards/tst/99" ->
            Req.Test.json(conn, %{
              "image_uris" => %{"normal" => "http://stub.test/image.jpg"}
            })

          "/image.jpg" ->
            Plug.Conn.resp(conn, 200, "downloaded jpeg")
        end
      end)

      assert {:ok, %{cached: 1, downloaded: 1, failed: 0}} =
               ImageCache.ensure_cached([91_001, 91_004],
                 cache_dir: cache_dir,
                 req_options: [plug: {Req.Test, ImageCache}]
               )
    end
  end
end
