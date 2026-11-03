import { Bridge } from './bridge.mjs';

// ponytail: one Durable Object for the whole relay (one home). A second home deploys its own relay.
export class Relay {
  constructor(state, env) { this.bridge = new Bridge({ env, storage: state.storage }); }
  fetch(request) { return this.bridge.fetch(request); }
}

export default {
  fetch(request, env) {
    return env.RELAY.get(env.RELAY.idFromName('relay')).fetch(request);
  },
};
