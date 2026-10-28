# Share Stack keeps manifest-declared components through the Android Gradle plugin.
# The app uses no reflection-based model or JSON mapping, so R8 can shrink the rest.
-dontwarn org.json.**
