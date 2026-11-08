// A consumer using only identify/unpack must link the real LibRaw archive.
// Mixing its *_ph.cpp no-processing placeholders into the archive makes this
// minimal consumer fail to link with duplicate processing definitions.
#include <libraw/libraw.h>
#include <iostream>
#include <memory>

int main() {
    auto raw = std::make_unique<LibRaw>();
    const int status = raw->open_buffer(nullptr, 0);
    if(status != LIBRAW_IO_ERROR) {
        std::cerr << "empty RAW metadata buffer was not rejected: " << status << '\n';
        return 1;
    }
    std::cout << "metadata-only LibRaw consumer linked: " << LibRaw::version() << '\n';
}
