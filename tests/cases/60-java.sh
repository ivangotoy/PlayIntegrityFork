# Host check of the Build field value conversion in EntryPoint.setField (java.lang only).
# Runs where a JDK 11+ `java` launcher exists (the CI image has one); skipped visibly otherwise.

JAVA_SRC="$ROOT/app/src/main/java/es/chiteroman/playintegrityfix/EntryPoint.java"
if ! command -v java >/dev/null 2>&1; then
    skip "java field conversion checks (no java)"
else
    JD="$WORK/java"; mkdir -p "$JD"
    {
        echo 'public class Conv {'
        echo '    static void LOG(String m) { System.out.println("LOG " + m); }'
        echo '    static Object result = "unset";'
        echo '    static void conv(Class<?> fieldType, String value) {'
        echo '        Object newValue = null;'
        sed -n "/if (fieldType == String.class) {/,/LOG(String.format(\"Couldn't convert '%s' to '%s' type\", value, fieldType));/p" "$JAVA_SRC"
        echo '            return;'
        echo '        }'
        echo '        result = newValue;'
        echo '    }'
        echo '    public static void main(String[] a) {'
        echo '        conv("long".equals(a[0]) ? long.class : int.class, a[1]);'
        echo '        System.out.println("RESULT " + result);'
        echo '    }'
        echo '}'
    } > "$JD/Conv.java"
    java "$JD/Conv.java" int 32 > "$JD/o1" 2>&1
    check "java conversion: int value" has_line "$JD/o1" "RESULT 32"
    java "$JD/Conv.java" long 1700000000000 > "$JD/o2" 2>&1
    check "java conversion: long value" has_line "$JD/o2" "RESULT 1700000000000"
    java "$JD/Conv.java" int "32 " > "$JD/o3" 2>&1
    check "java conversion: bad int is skipped, no exception" test "$?" -eq 0
    check "java conversion: bad int leaves the field unchanged" has_line "$JD/o3" "RESULT unset"
    java "$JD/Conv.java" long "x" > "$JD/o4" 2>&1
    check "java conversion: bad long is skipped, no exception" test "$?" -eq 0
fi
