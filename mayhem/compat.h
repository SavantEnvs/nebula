// Force-included into every C++ translation unit of the BASE tree (old code, current toolchain).
#include <cstdint>
#include <new>
#if defined(__cpp_lib_hardware_interference_size)
using std::hardware_destructive_interference_size;
#endif
