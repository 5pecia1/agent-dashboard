import 'dart:convert';

Map<String, dynamic> agyUsageFixtureData({String? resetAt}) =>
    (agyUsageFixture(resetAt: resetAt)['command']
            as Map<String, dynamic>)['data']
        as Map<String, dynamic>;

List<Map<String, dynamic>> agyFixtureBuckets(Map<String, dynamic> data) {
  final groups = data['groups'] as List<Object?>;
  final group = groups.first! as Map<String, dynamic>;
  return (group['buckets'] as List<Object?>).cast<Map<String, dynamic>>();
}

// Shape observed from agy 1.3.3 on 2026-10-11; account values are synthetic.
// Decode like the CLI response so nested maps remain extensible in edge cases.
Map<String, dynamic> agyUsageFixture({String? resetAt}) =>
    jsonDecode(
          jsonEncode({
            'status': 'SUCCESS',
            'num_turns': 0,
            'usage': {'input_tokens': 0, 'output_tokens': 0, 'total_tokens': 0},
            'response':
                'Human-readable text is intentionally unrelated to the quota.',
            'command': {
              'name': 'usage',
              'data': {
                'groups': [
                  {
                    'name': 'Gemini Models',
                    'description':
                        'Models within this group: Gemini Flash, Gemini Pro',
                    'buckets': [
                      {
                        'id': 'gemini-weekly',
                        'name': 'Weekly Limit Remaining',
                        'window': 'weekly',
                        'remaining_fraction': 0.81,
                        'reset_time': resetAt ?? '2030-10-17T09:58:41Z',
                      },
                      {
                        'id': 'gemini-5h',
                        'name': 'Five Hour Limit Remaining',
                        'window': '5h',
                        'remaining_fraction': 0.58,
                        'reset_time': resetAt ?? '2030-10-11T08:51:02Z',
                      },
                    ],
                  },
                  {
                    'name': 'Claude and GPT models',
                    'description':
                        'Models within this group: Claude Opus, Claude Sonnet, GPT-OSS',
                    'buckets': [
                      {
                        'id': '3p-weekly',
                        'name': 'Weekly Limit Remaining',
                        'window': 'weekly',
                        'remaining_fraction': 0.99,
                        'reset_time': resetAt ?? '2030-10-18T05:01:05Z',
                      },
                      {
                        'id': '3p-5h',
                        'name': 'Five Hour Limit Remaining',
                        'window': '5h',
                        'remaining_fraction': 0.98,
                        'reset_time': resetAt ?? '2030-10-11T10:01:05Z',
                      },
                    ],
                  },
                ],
              },
            },
          }),
        )
        as Map<String, dynamic>;
