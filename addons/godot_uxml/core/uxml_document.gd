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
## Cloned element -> the TemplateContainer (the expanded <Instance>) whose
## expansion made it (see instance_of). Empty without templates.
var element_instances: Dictionary = {}
## Cloned element -> the String index of its open tag `<` in its template
## file (see source_offset_of). Empty without templates.
var template_offsets: Dictionary = {}
## Element -> Array of DataBinding descriptors read from its <Bindings>
## child (see UxmlBindings). The <Bindings> elements themselves are no
## longer in the tree. Empty for a document without bindings.
var bindings: Dictionary = {}


## The file `element`'s attributes were authored in.
func path_of(element: UxmlElement) -> String:
	return element_paths.get(element, path)


## The String index of the `<` of `element`'s open tag in the source text
## of path_of(element): `open_tag_start` for an element of the entry file,
## the offset in the template file for a template clone. A control part
## has the offset of its control element.
func source_offset_of(element: UxmlElement) -> int:
	while element.part_of != null:
		element = element.part_of
	return template_offsets.get(element, element.open_tag_start)


## The TemplateContainer (the expanded <Instance>) whose template expansion
## made `element`, or null for an element authored in the entry file. For
## nested templates this is the innermost instance; call again on the
## result to reach the instance in the entry file. A control part answers
## for its control element.
func instance_of(element: UxmlElement) -> UxmlElement:
	if element == null:
		return null
	while element.part_of != null:
		element = element.part_of
	return element_instances.get(element)


func find_by_name(element_name: String) -> UxmlElement:
	return root.find_by_name(element_name) if root != null else null
