@tool
extends EditorPlugin
## godot_uxml editor plugin.
##
## The addon registers no editor UI: it is a pure-GDScript library under
## core/ (parser + cascade) and runtime/ plus the UxmlDocument Control.
## Enabling the plugin only guarantees the addon scripts compile inside the
## editor — UxmlDocument works in exported games without it.
