# Build Stage
FROM ghcr.io/evanrichter/cargo-fuzz:latest as builder

## Add source code to the build stage.
ADD . /src
WORKDIR /src

RUN echo building instrumented harnesses && \
    bash -c "pushd src/shared/elf64/fuzz && cargo +nightly -Z sparse-registry fuzz build && popd" && \
    mv src/shared/elf64/fuzz/target/x86_64-unknown-linux-gnu/release/elf64_parse /elf64_parse && \
    echo done

RUN echo building non-instrumented harnesses && \
    export RUSTFLAGS="--cfg fuzzing -Clink-dead-code -Cdebug-assertions -C codegen-units=1" && \
    bash -c "pushd src/shared/elf64/fuzz && cargo +nightly -Z sparse-registry build --release && popd" && \
    mv src/shared/elf64/fuzz/target/release/elf64_parse /elf64_parse_no_inst && \
    echo done

# Package Stage
FROM rustlang/rust:nightly

COPY --from=builder /elf64_parse /elf64_parse_no_inst /
RUN mkdir /testsuite
COPY --from=builder /bin/ls /testsuite/
