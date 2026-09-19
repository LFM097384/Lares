// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => '炉灵';

  @override
  String get commonCancel => '算了';

  @override
  String get commonConfirm => '好';

  @override
  String get commonDone => '完成';

  @override
  String get homeAddCircle => '加个圈子';

  @override
  String get homeAddCircleHint => '比如:家人、死党群、考研搭子';

  @override
  String get homePasteInvite => '有邀请链接?粘贴进圈';

  @override
  String homeKickedBy(String who) {
    return '你被$who请出了房间';
  }

  @override
  String get homeKickedByAdmin => '管理员';
}
