import 'package:my_dashboard/src/integrations/data/grok_bot_models.dart';

GrokBotPreview readInstalledGrokBotPreview() =>
    const GrokBotPreview.unsupported();

Future<GrokBotAuthReadResult> unlockInstalledGrokBot(GrokBotPreview preview) =>
    Future<GrokBotAuthReadResult>.value(GrokBotAuthReadResult(preview.status));
