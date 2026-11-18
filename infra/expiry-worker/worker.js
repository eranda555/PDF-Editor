export default {
  async scheduled(event, env, context) {
    const invoke = async (base, path) => {
      if (!base || !base.startsWith('https://')) throw new Error('HTTPS service URL required');
      const response = await fetch(new URL(path, base), {
        method: 'POST', headers: {Authorization: `Bearer ${env.INTERNAL_TOKEN}`},
        signal: AbortSignal.timeout(850000),
      });
      if (!response.ok) throw new Error('Scheduled service request failed');
    };
    context.waitUntil(Promise.all([
      invoke(env.API_URL, '/internal/purge'),
      invoke(env.QUEUE_URL, '/internal/drain'),
    ]));
  },
};
