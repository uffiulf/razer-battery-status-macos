CXX = clang++
# Universal Binary: Support both Apple Silicon (arm64) and Intel (x86_64)
ARCH_FLAGS = -arch arm64 -arch x86_64
CXXFLAGS = -std=c++17 -Wall -Wextra -O2 $(ARCH_FLAGS)
OBJCFLAGS = -x objective-c++ -std=c++17 -fobjc-arc -Wall -Wextra -O2 $(ARCH_FLAGS)

# IOKit-based implementation - no HIDAPI needed
FRAMEWORKS = -framework IOKit -framework Cocoa -framework CoreFoundation \
             -framework UserNotifications -framework ApplicationServices \
             -framework CoreVideo

SRCDIR = src
SOURCES = $(SRCDIR)/RazerDevice.cpp \
          $(SRCDIR)/SmoothScrollEngine.mm \
          $(SRCDIR)/ScrollInterceptor.mm \
          $(SRCDIR)/main.mm
OBJECTS = $(SOURCES:.cpp=.o)
OBJECTS := $(OBJECTS:.mm=.o)

TARGET = RazerBatteryMonitor

all: $(TARGET)

$(TARGET): $(OBJECTS)
	$(CXX) $(ARCH_FLAGS) $(OBJECTS) -o $(TARGET) $(FRAMEWORKS)

$(SRCDIR)/RazerDevice.o: $(SRCDIR)/RazerDevice.cpp $(SRCDIR)/RazerDevice.hpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(SRCDIR)/SmoothScrollEngine.o: $(SRCDIR)/SmoothScrollEngine.mm $(SRCDIR)/SmoothScrollEngine.hpp
	$(CXX) $(OBJCFLAGS) -c $< -o $@

$(SRCDIR)/ScrollInterceptor.o: $(SRCDIR)/ScrollInterceptor.mm $(SRCDIR)/ScrollInterceptor.hpp $(SRCDIR)/SmoothScrollEngine.hpp
	$(CXX) $(OBJCFLAGS) -c $< -o $@

$(SRCDIR)/main.o: $(SRCDIR)/main.mm $(SRCDIR)/RazerDevice.hpp $(SRCDIR)/ScrollInterceptor.hpp
	$(CXX) $(OBJCFLAGS) -c $< -o $@

clean:
	rm -f $(OBJECTS) $(TARGET)

.PHONY: all clean
