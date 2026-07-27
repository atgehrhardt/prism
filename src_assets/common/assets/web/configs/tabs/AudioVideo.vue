<script setup>
import {onMounted, ref} from 'vue'
import {$tp} from '../../platform-i18n'
import PlatformLayout from '../../PlatformLayout.vue'
import AdapterNameSelector from './audiovideo/AdapterNameSelector.vue'
import DisplayOutputSelector from './audiovideo/DisplayOutputSelector.vue'
import DisplayDeviceOptions from "./audiovideo/DisplayDeviceOptions.vue";
import DisplayModesSettings from "./audiovideo/DisplayModesSettings.vue";
import Checkbox from "../../Checkbox.vue";

const props = defineProps([
  'platform',
  'config',
])

const config = ref(props.config)

const audioSinks = ref([])

onMounted(async () => {
  try {
    const r = await fetch('./api/audio-sinks')
    if (r.ok) {
      const sinks = await r.json()
      // Keep a manually-entered sink that no longer exists selectable.
      const current = config.value.prism_default_sink
      if (current && !sinks.some((s) => s.name === current)) {
        sinks.push({name: current, description: current})
      }
      audioSinks.value = sinks
    }
  } catch (e) {
    // Leave audioSinks empty; the UI falls back to a text input.
  }
})
</script>

<template>
  <div id="audio-video" class="config-page">
    <!-- Audio Sink -->
    <div class="mb-3">
      <label for="audio_sink" class="form-label">{{ $t('config.audio_sink') }}</label>
      <input type="text" class="form-control" id="audio_sink"
             :placeholder="$tp('config.audio_sink_placeholder', 'alsa_output.pci-0000_09_00.3.analog-stereo')"
             v-model="config.audio_sink" />
      <div class="form-text">
        {{ $tp('config.audio_sink_desc') }}<br>
        <PlatformLayout :platform="platform">
          <template #windows>
            <pre>tools\audio-info.exe</pre>
          </template>
          <template #freebsd>
            <pre>pacmd list-sinks | grep "name:"</pre>
            <pre>pactl info | grep Source</pre>
          </template>
          <template #linux>
            <pre>pacmd list-sinks | grep "name:"</pre>
            <pre>pactl info | grep Source</pre>
          </template>
          <template #macos>
            <a href="https://github.com/mattingalls/Soundflower" target="_blank">Soundflower</a><br>
            <a href="https://github.com/ExistentialAudio/BlackHole" target="_blank">BlackHole</a>.
          </template>
        </PlatformLayout>
      </div>
    </div>


    <PlatformLayout :platform="platform">
      <template #linux>
        <!-- Prism Default Sink -->
        <div class="mb-3">
          <label for="prism_default_sink" class="form-label">{{ $t('config.prism_default_sink') }}</label>
          <select v-if="audioSinks.length > 0" class="form-select" id="prism_default_sink"
                  v-model="config.prism_default_sink">
            <option value="">{{ $t('config.prism_default_sink_restore') }}</option>
            <option v-for="sink in audioSinks" :key="sink.name" :value="sink.name">
              {{ sink.description }} ({{ sink.name }})
            </option>
          </select>
          <input v-else type="text" class="form-control" id="prism_default_sink"
                 :placeholder="$tp('config.prism_default_sink_placeholder', 'alsa_output.pci-0000_09_00.3.analog-stereo')"
                 v-model="config.prism_default_sink" />
          <div class="form-text">{{ $t('config.prism_default_sink_desc') }}</div>
        </div>
      </template>
    </PlatformLayout>

    <PlatformLayout :platform="platform">
      <template #windows>
        <!-- Virtual Sink -->
        <div class="mb-3">
          <label for="virtual_sink" class="form-label">{{ $t('config.virtual_sink') }}</label>
          <input type="text" class="form-control" id="virtual_sink" :placeholder="$t('config.virtual_sink_placeholder')"
                 v-model="config.virtual_sink" />
          <div class="form-text">{{ $t('config.virtual_sink_desc') }}</div>
        </div>

      </template>
    </PlatformLayout>

    <!-- Disable Audio -->
    <Checkbox class="mb-3"
              id="stream_audio"
              locale-prefix="config"
              v-model="config.stream_audio"
              default="true"
    ></Checkbox>

    <AdapterNameSelector
        :platform="platform"
        :config="config"
    />

    <DisplayOutputSelector
      :platform="platform"
      :config="config"
    />

    <DisplayDeviceOptions
      :platform="platform"
      :config="config"
    />

    <!-- Display Modes -->
    <DisplayModesSettings
        :platform="platform"
        :config="config"
    />

  </div>
</template>

<style scoped>
</style>
