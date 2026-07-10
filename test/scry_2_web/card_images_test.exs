defmodule Scry2Web.CardImagesTest do
  use ExUnit.Case, async: true

  alias Scry2Web.CardImages

  setup do
    cache_dir =
      Path.join(System.tmp_dir!(), "scry2_card_images_#{System.unique_integer([:positive])}")

    File.mkdir_p!(cache_dir)
    on_exit(fn -> File.rm_rf!(cache_dir) end)
    %{cache_dir: cache_dir}
  end

  defp cache_file!(cache_dir, arena_id, variant) do
    suffix = if variant == :art, do: "-art", else: ""
    File.write!(Path.join(cache_dir, "#{arena_id}#{suffix}.jpg"), "fake jpeg")
  end

  describe "empty/0" do
    test "has an empty set per variant" do
      assert CardImages.empty() == %{full: MapSet.new(), art: MapSet.new()}
    end
  end

  describe "merge_requests/3" do
    test "adds unique ids to the requested variants only" do
      requests = CardImages.merge_requests(CardImages.empty(), [101, 102, 101], [:full])

      assert requests.full == MapSet.new([101, 102])
      assert requests.art == MapSet.new()
    end

    test "unions across successive calls without dropping earlier requests" do
      requests =
        CardImages.empty()
        |> CardImages.merge_requests([101], [:art, :full])
        |> CardImages.merge_requests([202], [:full])

      assert requests.full == MapSet.new([101, 202])
      assert requests.art == MapSet.new([101])
    end

    test "rejects nil ids" do
      requests = CardImages.merge_requests(CardImages.empty(), [nil, 101], [:full])
      assert requests.full == MapSet.new([101])
    end
  end

  describe "refresh_cached/3" do
    test "adds requested ids whose image file exists, per variant", %{cache_dir: cache_dir} do
      cache_file!(cache_dir, 101, :full)
      cache_file!(cache_dir, 101, :art)
      cache_file!(cache_dir, 102, :full)

      requests = CardImages.merge_requests(CardImages.empty(), [101, 102, 103], [:art, :full])
      cached = CardImages.refresh_cached(requests, CardImages.empty(), cache_dir)

      assert cached.full == MapSet.new([101, 102])
      assert cached.art == MapSet.new([101])
    end

    test "never removes ids already recorded as cached", %{cache_dir: cache_dir} do
      # 909 was cached earlier in the session (e.g. checked before this
      # request round); its file check must not be repeated or reversed.
      already_cached = %{full: MapSet.new([909]), art: MapSet.new()}
      requests = CardImages.merge_requests(CardImages.empty(), [101], [:full])

      cache_file!(cache_dir, 101, :full)
      cached = CardImages.refresh_cached(requests, already_cached, cache_dir)

      assert cached.full == MapSet.new([101, 909])
    end
  end

  describe "missing/2" do
    test "returns requested-but-uncached ids per variant" do
      requests = CardImages.merge_requests(CardImages.empty(), [101, 102], [:art, :full])
      cached = %{full: MapSet.new([101]), art: MapSet.new()}

      assert CardImages.missing(requests, cached) == %{
               full: [102],
               art: [101, 102]
             }
    end

    test "omits variants with nothing missing" do
      requests = CardImages.merge_requests(CardImages.empty(), [101], [:full])
      cached = %{full: MapSet.new([101]), art: MapSet.new()}

      assert CardImages.missing(requests, cached) == %{}
    end
  end
end
