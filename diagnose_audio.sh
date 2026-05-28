#!/bin/bash
# Audio crackle diagnostic — run this in Terminal.app while playing audio
# It captures coreaudiod IO cycle overloads, aggregate device issues, and CPU spikes

echo "🔍 Audio Crackle Diagnostic — press Ctrl+C to stop"
echo "   Listening for: IO overloads, xruns, aggregate device glitches..."
echo ""

# Stream all audio-related log messages in real-time
sudo log stream \
  --predicate 'process == "coreaudiod" 
    OR sender contains "IOAudio" 
    OR sender contains "HALC" 
    OR eventMessage contains "overload" 
    OR eventMessage contains "xrun" 
    OR eventMessage contains "skipping cycle" 
    OR eventMessage contains "aggregate" 
    OR eventMessage contains "glitch"
    OR eventMessage contains "underrun"
    OR eventMessage contains "IOWorkLoop"
    OR eventMessage contains "cycle budget"
    OR eventMessage contains "took too long"
    OR (process == "FineTune" AND eventMessage contains "audio")' \
  --level debug \
  --style compact
