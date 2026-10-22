# Bug 3 — Fix

Single exit that always closes `ap`.

```diff
--- a/homa_devel.c
+++ b/homa_devel.c
@@ homa_snprintf
-	int new_chars;
-	va_list ap;
-
-	va_start(ap, format);
-
-	if (used >= (size - 1))
-		return used;
-
-	new_chars = vsnprintf(buffer + used, size - used, format, ap);
-	if (new_chars < 0)
-		return used;
-	if (new_chars >= (size - used))
-		return size - 1;
-	return used + new_chars;
+	int new_chars = used;
+	va_list ap;
+
+	va_start(ap, format);
+	if (used < (size - 1)) {
+		new_chars = vsnprintf(buffer + used, size - used, format, ap);
+		if (new_chars < 0)
+			new_chars = used;
+		else if (new_chars >= (size - used))
+			new_chars = size - 1;
+		else
+			new_chars += used;
+	}
+	va_end(ap);
+	return new_chars;
```
