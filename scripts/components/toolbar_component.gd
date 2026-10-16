class_name ToolbarComponent
extends HFlowContainer
## Toolbar subscene root: binds its buttons as typed properties so the host
## (main.gd) and LayoutComponent/ThemeComponent can reach them without
## relying on Main.tscn's owner-scoped % bindings. The shell stays authored
## in toolbar.tscn; actions stay connected in main.gd via `pressed` signals.

@onready var menu_btn: Button = %MenuBtn
@onready var note_title: Label = %NoteTitle
@onready var new_btn: Button = %NewBtn
@onready var mode_btn: Button = %ModeBtn
@onready var help_btn: Button = %HelpBtn
@onready var export_btn: MenuButton = %ExportBtn
@onready var backlinks_btn: Button = %BacklinksBtn
## Dedicated graph toggle, the toolbar's outermost control (top-right corner).
## Never collapsed into the ⋮ overflow: it is the only way to the dock, and the
## only graph entry point on phones.
@onready var graph_toggle_btn: Button = %GraphToggleBtn
@onready var more_btn: MenuButton = %MoreBtn
@onready var more_menu: PopupMenu = %MoreMenu