#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    fuzz(data);
});

fn fuzz(data: &[u8]) -> Option<()> {
    let elf = elf64::Elf::new(data)?;

    let _: Vec<()> = elf.program_headers().map(|_| ()).collect();
    let _: Vec<()> = elf.section_headers().map(|_| ()).collect();
    let _: Vec<()> = elf.relocations().map(|_| ()).collect();

    Some(())
}
