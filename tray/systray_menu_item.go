package main

import (
	"github.com/getlantern/systray"
)

// systrayMenuItem adapts *systray.MenuItem to the updater.MenuItem interface.
type systrayMenuItem struct {
	item *systray.MenuItem
}

func (s *systrayMenuItem) SetTitle(title string) { s.item.SetTitle(title) }
func (s *systrayMenuItem) Disable()              { s.item.Disable() }
func (s *systrayMenuItem) Enable()               { s.item.Enable() }
func (s *systrayMenuItem) ClickedCh() <-chan struct{} {
	return s.item.ClickedCh
}
