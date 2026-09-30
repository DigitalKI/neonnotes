class_name MoreMenuComponent
extends PopupMenu
## Scene-authored "\u22ee More" overflow menu, a child of %MoreBtn in
## toolbar.tscn. Its items are serialized in the scene; this script only owns
## the action ids so main.gd never uses magic numbers. MenuButton never shows a
## scene-authored child popup by itself \u2014 main.gd opens it from
## MoreBtn.pressed (same pattern as export_menu.tscn).

const ID_SAVE_NOW := 30
const ID_DELETE_NOTE := 31
const ID_TRASH := 32
const ID_HELP := 10
const ID_BACKLINKS := 11
const ID_GRAPH := 12
