# RDL discovery regression

User-provided iPhone/right-headphone recording, inspected on 2026-09-12.
Original schema-8 files are preserved byte-for-byte under canonical filenames.
The source recording has 1,351 samples over 27 seconds and zero v1 events.

Six repeated acceleration waveforms are visible, with negative vertical
acceleration landmarks near 3.38, 6.68, 10.08, 13.20, 18.10 and 22.36 seconds.
There is a longer pause after the fourth pattern. The user recalled six or more
reps. These are development waveform annotations, not independently measured
anatomical boundaries, speed measurements, or held-out evaluation labels.

The regression checks one pattern completion per broad waveform interval,
three-cycle learning, frozen feature reliability, and legacy replay hashes.
The landmarks are not fed into the detector or used as physical turnarounds.
