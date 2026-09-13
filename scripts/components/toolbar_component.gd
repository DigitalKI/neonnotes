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
@onready var graph_btn: Button = %GraphBtn
@onready var more_btn: MenuButton = %MoreBtn