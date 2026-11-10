// Alexa smart home skills must be hosted on AWS Lambda. This function only forwards
// each directive to your relay and returns its reply. Environment: RELAY_URL, LAMBDA_SECRET.
// Restrict its Alexa trigger to your skill ID in the Lambda console.
export const handler = async (event) => {
  try {
    const response = await fetch(new URL('/alexa', process.env.RELAY_URL), {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-luma-relay-secret': process.env.LAMBDA_SECRET },
      body: JSON.stringify(event),
      signal: AbortSignal.timeout(6500), // Alexa waits about 8 s for a reply
    });
    if (!response.ok) throw new Error(`relay ${response.status}`);
    return await response.json();
  } catch (error) {
    console.error('relay forward failed', error);
    const { header = {}, endpoint } = event?.directive ?? {};
    return { event: {
      header: { namespace: 'Alexa', name: 'ErrorResponse', payloadVersion: '3', messageId: crypto.randomUUID(), ...(header.correlationToken ? { correlationToken: header.correlationToken } : {}) },
      ...(endpoint ? { endpoint } : {}),
      payload: { type: 'BRIDGE_UNREACHABLE', message: 'The Luma relay could not be reached.' },
    } };
  }
};
