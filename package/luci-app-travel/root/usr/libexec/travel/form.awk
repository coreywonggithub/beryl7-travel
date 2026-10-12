# Reads a login page's first <form> for /etc/travelmate/auto.login (2026-10-06).
# Prints one line per item, separated by \037 (the ASCII unit separator: the shell's
# read merges runs of tabs, which made empty fields vanish and shift the rest, 2026-10-06):
#   FORM  <method>  <action>
#   F     <type>    <name>  <value>  <flags: c = checked, r = required>
# Types are the input types (text, password, hidden, checkbox, radio, submit, ...),
# "button-<type>" for <button>, and "select" (its selected or first option's value).
# A small reader for ordinary forms, not a full HTML parser: a page built by
# JavaScript has no form to read, and that is reported, not guessed.

BEGIN { RS = "<"; inform = 0; done = 0; selname = "" }

function attr(t, a,    re, v) {
	re = "(^|[ \t\r\n])" a "[ \t\r\n]*=[ \t\r\n]*(\"[^\"]*\"|'[^']*'|[^ \t\r\n>]+)"
	if (!match(tolower(t), re))
		return ""
	v = substr(t, RSTART, RLENGTH)
	sub(/^[ \t\r\n]*[^=]*=[ \t\r\n]*/, "", v)
	if (v ~ /^"/ || v ~ /^'/)
		v = substr(v, 2, length(v) - 2)
	gsub(/&amp;/, "\\&", v)
	gsub(/&quot;/, "\"", v)
	gsub(/&#39;|&#x27;|&apos;/, "'", v)
	gsub(/&lt;/, "<", v)
	gsub(/&gt;/, ">", v)
	gsub(/[\t\r\n]/, " ", v)
	return v
}

function flag(t, f) {
	return (tolower(t) ~ ("(^|[ \t\r\n])" f "([ \t\r\n=/]|$)")) ? 1 : 0
}

{
	if (done)
		next
	tag = $0
	sub(/>.*/, "", tag)
	# the tag's name, closing ones included ("/form"); no /.../i in awk: lower-case first
	name = ""
	if (match(tolower(tag), /^\/?[a-z0-9!-]+/))
		name = substr(tolower(tag), RSTART, RLENGTH)

	if (name == "form" && !inform) {
		inform = 1
		printf "FORM\037%s\037%s\n", tolower(attr(tag, "method")), attr(tag, "action")
		next
	}
	if (!inform)
		next
	if (name == "/form") {
		done = 1
		next
	}
	if (name == "input") {
		type = tolower(attr(tag, "type"))
		if (type == "")
			type = "text"
		printf "F\037%s\037%s\037%s\037%s%s\n", type, attr(tag, "name"), attr(tag, "value"), (flag(tag, "checked") ? "c" : ""), (flag(tag, "required") ? "r" : "")
	}
	else if (name == "button") {
		type = tolower(attr(tag, "type"))
		if (type == "")
			type = "submit"
		printf "F\037button-%s\037%s\037%s\037\n", type, attr(tag, "name"), attr(tag, "value")
	}
	else if (name == "select") {
		selname = attr(tag, "name")
		selval = ""
		selset = 0
	}
	else if (name == "option" && selname != "") {
		if (!selset || flag(tag, "selected")) {
			selval = attr(tag, "value")
			selset = 1
		}
	}
	else if (name == "/select" && selname != "") {
		printf "F\037select\037%s\037%s\037\n", selname, selval
		selname = ""
	}
}
