class_name UxmlDocumentModel
extends RefCounted
## The semantic document: a parsed UXML tree plus every stylesheet it pulls in.
##
## This is the input the style resolver consumes. It deliberately holds only
## what the files said — computed styles are produced per resolve() call and
## never stored here.
##
## Sheets are flat in load order; `style_roots` records which subtree each
## entry sheet is attached to (`<Style src>` scopes to its parent element).
## A rule only applies to elements inside its sheet's scope.

var source: String = ""
## Canonical path the document was loaded from ("" for load_source callers).
var path: String = ""
var root: UxmlElement = null
## Array of {index: int, source: String, origin: String, items: Array,
##           scope: UxmlElement}.
var sheets: Array = []
## Array of {sheet: int, scope: UxmlElement}.
var style_roots: Array = []
## Array of diagnostic Dictionaries (see UxmlDiagnostic).
var warnings: Array = []
## Elements cloned from a template file -> that file's path. Relative
## references in their attributes (image, item-template) resolve against it.
## Empty for a document without templates.
var element_paths: Dictionary = {}
## Element -> Array of DataBinding descriptors read from its <Bindings>
## child (see UxmlBindings). The <Bindings> elements themselves are no
## longer in the tree. Empty for a document without bindings.
var bindings: Dictionary = {}


## The file `element`'s attributes were authored in.
func path_of(element: UxmlElement) -> String:
	return element_paths.get(element, path)


func find_by_name(element_name: String) -> UxmlElement:
	return root.find_by_name(element_name) if root != null else null
