//go:build ignore

package main

import (
	"image"
	"image/color"
	"image/png"
	"os"
)

func main() {
	img := image.NewRGBA(image.Rect(0, 0, 32, 32))
	bg := color.RGBA{R: 30, G: 30, B: 46, A: 255}  // dark navy
	fg := color.RGBA{R: 137, G: 180, B: 250, A: 255} // blue

	for y := 0; y < 32; y++ {
		for x := 0; x < 32; x++ {
			img.Set(x, y, bg)
		}
	}

	// Simple "S" shape (5×7 pixel strokes at centre)
	pixels := [][2]int{
		{11, 8}, {12, 8}, {13, 8}, {14, 8}, {15, 8}, {16, 8}, {17, 8}, {18, 8}, {19, 8}, {20, 8},
		{10, 9}, {10, 10}, {10, 11}, {10, 12}, {10, 13},
		{11, 14}, {12, 14}, {13, 14}, {14, 14}, {15, 14}, {16, 14}, {17, 14}, {18, 14}, {19, 14}, {20, 14},
		{21, 15}, {21, 16}, {21, 17}, {21, 18}, {21, 19},
		{11, 20}, {12, 20}, {13, 20}, {14, 20}, {15, 20}, {16, 20}, {17, 20}, {18, 20}, {19, 20}, {20, 20},
	}
	for _, p := range pixels {
		img.Set(p[0], p[1], fg)
	}

	os.MkdirAll("assets", 0755)
	f, _ := os.Create("assets/icon.png")
	defer f.Close()
	png.Encode(f, img)
}
