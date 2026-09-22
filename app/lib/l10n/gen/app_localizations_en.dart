// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Lares Circle';

  @override
  String get chatCollapse => 'Hide messages';

  @override
  String get chatComposerHint => 'Say something, or drop in a picture';

  @override
  String get chatEmpty =>
      'It\'s quiet here. Anything you want to say, or a picture, can go here.';

  @override
  String get chatExpand => 'Show messages';

  @override
  String get chatImageMissing => 'This picture didn\'t come through';

  @override
  String get chatImageOpen => 'Picture, tap to open it larger';

  @override
  String get chatImagePickFailed => 'Couldn\'t open the picture';

  @override
  String get chatImagePickUnsupported =>
      'Picking pictures isn\'t supported in this version yet';

  @override
  String get chatImageSendFailed => 'That picture didn\'t send';

  @override
  String get chatImageViewer => 'Full-size picture, tap outside to close';

  @override
  String get chatImageViewerClose => 'Close the full-size picture';

  @override
  String chatRemaining(int left) {
    String _temp0 = intl.Intl.pluralLogic(
      left,
      locale: localeName,
      other: '$left characters left',
      one: '1 character left',
    );
    return '$_temp0';
  }

  @override
  String get chatSend => 'Send';

  @override
  String get chatSendFailed => 'Didn\'t send';

  @override
  String get chatSendImage => 'Send a picture';

  @override
  String get chatUnread => 'New messages';

  @override
  String get commonCancel => 'Never mind';

  @override
  String get commonClose => 'Close';

  @override
  String get commonConfirm => 'OK';

  @override
  String get commonCopied => 'Copied';

  @override
  String get commonCopy => 'Copy';

  @override
  String get commonDone => 'Done';

  @override
  String get commonGotIt => 'Got it';

  @override
  String get commonListSeparator => ', ';

  @override
  String get commonNoThanks => 'No thanks';

  @override
  String get commonSave => 'Save';

  @override
  String get e2eeConfirmBody =>
      'Encryption only works when **everyone in the circle turns it on**. If you are the only one, they will not be able to hear you and you will not be able to hear them — your voices never reach the same lock. Talk to the circle first and turn it on together.';

  @override
  String get e2eeConfirmTitle => 'Everyone in the circle has to turn this on';

  @override
  String get e2eeConfirmYes => 'We agreed — turn it on';

  @override
  String get e2eeCostNotice =>
      'Once on: the server sees nothing, so **transcription is off**, and the **AI Lares** is **unavailable** in this circle (it only works in circles without encryption).';

  @override
  String get e2eeEveryoneNotice =>
      'Everyone in the circle has to turn this on, or you will not be able to hear each other.';

  @override
  String get e2eeKeyLocalNotice =>
      'The key is derived from your circle passphrase, stays on this device, and never reaches the server.';

  @override
  String get e2eeTitle => 'End-to-end encryption';

  @override
  String get homeAddCircle => 'New circle';

  @override
  String get homeAddCircleConfirm => 'Make one';

  @override
  String get homeAddCircleHint => 'Family, close friends, study group…';

  @override
  String get homeAvailable => 'I\'m free';

  @override
  String get homeAvailableOffDesc =>
      'Put it out there so your circles know you can talk · long-press to pick circles';

  @override
  String homeAvailableOnDesc(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n circles can see you',
      one: '1 circle can see you',
    );
    return '$_temp0 · whoever comes first is who you talk to, and once you\'re in, the others stop seeing you';
  }

  @override
  String get homeAvailablePickBody =>
      'Once you put it out there, people in these circles will see that you\'re free.\nWhoever reaches you first is who you talk to — from that moment the other circles stop seeing you.';

  @override
  String get homeAvailablePickConfirm => 'Just these';

  @override
  String get homeAvailablePickTitle => 'Which circles can see you';

  @override
  String get homeCircleEmpty => 'Nobody here yet — go in and wait?';

  @override
  String homeCircleOnline(int online) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: '$online people here',
      one: '1 person here',
    );
    return '$_temp0';
  }

  @override
  String homeCircleOnlineAndWaiting(int online, String waitingNames) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: '$online people here',
      one: '1 person here',
    );
    return '$_temp0 · $waitingNames free to talk';
  }

  @override
  String homeCircleOnlineWithNames(int online, String names) {
    String _temp0 = intl.Intl.pluralLogic(
      online,
      locale: localeName,
      other: '$online people here',
      one: '1 person here',
    );
    return '$_temp0 · $names';
  }

  @override
  String homeCircleWaitingOnly(String waitingNames) {
    return '$waitingNames — free to talk, waiting for someone';
  }

  @override
  String get homeDeleteCircle => 'Delete this circle';

  @override
  String get homeEmptyRoomHint => 'Tap a circle on the left to go in';

  @override
  String get homeInviteBody =>
      'Send this link to a friend — one tap and they\'re in (they can also paste it in the app):';

  @override
  String get homeInvitedCircleFallback => 'A friend\'s circle';

  @override
  String get homeInviteFriends => 'Invite friends';

  @override
  String get homeInviteFriendsDesc => 'Copy the invite link and send it over';

  @override
  String get homeInviteIncludePasscode => 'Put the passphrase in the link';

  @override
  String get homeInviteIncludePasscodeE2ee =>
      '⚠️ This circle is end-to-end encrypted — the passphrase is the key. If the link gets forwarded or screenshotted, the conversations are no longer private.';

  @override
  String get homeInviteIncludePasscodeHint =>
      'They will not have to ask you for it separately';

  @override
  String homeInviteTitle(String circleName) {
    return 'Invite friends to “$circleName”';
  }

  @override
  String get homeJoinCircle => 'Join';

  @override
  String homeKickedBy(String who) {
    return '$who removed you from the room';
  }

  @override
  String get homeKickedByAdmin => 'An admin';

  @override
  String get homeKnockModeConfirmBody =>
      'This is a setting for the whole circle, not just for you — change it and it changes for everyone. Anyone in the circle can change it back, too.';

  @override
  String get homeKnockModeConfirmTitle => 'This changes it for everyone';

  @override
  String get homeKnockModeConfirmYes => 'Change it';

  @override
  String get homeKnockModeDesc =>
      'When on, people outside the circle need someone inside to let them in';

  @override
  String get homeKnockModeEveryoneNotice =>
      'The whole circle shares this one setting — if you change it, you change it for everyone.';

  @override
  String get homeKnockModeOff => 'Knock mode: off (tap to turn on)';

  @override
  String get homeKnockModeOn => 'Knock mode: on (tap to turn off)';

  @override
  String get homePasteInvite => 'Have an invite link? Paste it';

  @override
  String get homePasteInviteHint => 'lares://circle/… or a circle id';

  @override
  String get homePasteInvitePasscode =>
      'Circle passcode (if your friend sent one)';

  @override
  String get homePasteInvitePasscodeHint =>
      'Leave it blank if you don\'t have one — you can add it later';

  @override
  String get homePasteInviteTitle => 'Paste an invite link';

  @override
  String get homePrimaryCircleAlready => 'Already your main circle';

  @override
  String get homePrimaryCircleAlreadyDesc =>
      'The widget, quick settings and the tray all drop you into this one';

  @override
  String get homePrimaryCircleSet => 'Make this the main circle';

  @override
  String get homePrimaryCircleSetDesc =>
      'One tap on the home screen widget takes you straight here';

  @override
  String get homePrimaryCircleTooltip =>
      'Main circle · one tap from the widget';

  @override
  String get homeRename => 'Change nickname';

  @override
  String get homeRenameConfirm => 'Use this';

  @override
  String get homeRenameHint => 'Nickname';

  @override
  String get homeRenameTitle => 'What should the circle call you?';

  @override
  String get moderationBlock => 'Block this person';

  @override
  String get moderationBlockHint =>
      'You won\'t hear their voice or see their messages';

  @override
  String get moderationBlockShort => 'Block';

  @override
  String get moderationNoUserId => 'Couldn\'t find a user ID';

  @override
  String get moderationSuggestBlockBody =>
      'Once blocked, you won\'t hear their voice or see their messages.';

  @override
  String get moderationSuggestBlockTitle => 'Block them too?';

  @override
  String get moderationUnblock => 'Unblock';

  @override
  String get moderationUnblockHint => 'Their voice and messages come back';

  @override
  String noteListen(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count notes (hold to leave one)',
      one: '1 note (hold to leave one)',
      zero: 'Hold to leave a note',
    );
    return '$_temp0';
  }

  @override
  String get noteRecordHint => 'Hold to leave a note';

  @override
  String get p2pCaveatHasTurn =>
      'Also, about a quarter of network setups can\'t connect directly. Those will go through the relay server you set up.';

  @override
  String get p2pCaveatNoTurn =>
      'Also, about a quarter of network setups can\'t connect directly. Those need a relay server (TURN) filled in under settings.';

  @override
  String get p2pCaveats =>
      '⚠️ One to one only, and there\'s no text, no images and no encryption badge here — those all need a server.';

  @override
  String p2pCharCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count characters',
      one: '1 character',
    );
    return '$_temp0';
  }

  @override
  String get p2pCodeCopied => 'Connect code copied. Send it over.';

  @override
  String get p2pCodeSendBack => '② Send this back to them';

  @override
  String get p2pCodeSendToPeer => '① Send this to the other person';

  @override
  String get p2pConnect => 'Connect';

  @override
  String get p2pCopy => 'Copy';

  @override
  String get p2pErrorCorrupted =>
      'The connect code is incomplete — part of it probably got lost in the copy.';

  @override
  String get p2pErrorNotLaresCode =>
      'That text isn\'t a Lares connect code. Worth another look.';

  @override
  String get p2pErrorVersionMismatch =>
      'Their Lares version is too far from yours. Update and try again.';

  @override
  String get p2pErrorWrongKind =>
      'Wrong one — that\'s an opening code. You want the answer code they sent back.';

  @override
  String get p2pNoServerBody =>
      'You and the other person trade one connect code, and the audio goes straight between the two devices.\nSend the code however you like — a chat app, a text message, or just read it out.';

  @override
  String get p2pNoServerTitle => 'No server involved';

  @override
  String get p2pPasteFromClipboard => 'Paste from clipboard';

  @override
  String get p2pPasteIncomingLabel => '① Paste the code they sent you';

  @override
  String get p2pPasteReplyLabel => '② Paste the code they sent back';

  @override
  String get p2pPreparing => 'Getting the connection details ready…';

  @override
  String get p2pRoleAnswererBody =>
      'Paste in the code they sent, then send back the one it makes.';

  @override
  String get p2pRoleAnswererTitle => 'They sent me a code';

  @override
  String get p2pRoleMeshBody =>
      'The server hands the connect codes around, so nobody has to pass them by hand. One person is picked automatically to relay the audio — a computer first, since it\'s plugged in and has a steadier connection.';

  @override
  String get p2pRoleMeshTitle => 'Everyone in the circle (up to 4)';

  @override
  String get p2pRoleOffererBody =>
      'Make a connect code and send it over, then wait for the one they send back.';

  @override
  String get p2pRoleOffererTitle => 'I\'ll start';

  @override
  String get p2pStatusClosed => 'Disconnected';

  @override
  String get p2pStatusConnected => 'Connected. Go ahead and talk.';

  @override
  String get p2pStatusConnecting => 'Connecting…';

  @override
  String get p2pStatusFailed => 'Couldn\'t connect';

  @override
  String get p2pStatusWaitingForPeer => 'Waiting on the other side';

  @override
  String get p2pTitle => 'Direct call';

  @override
  String get policyAgree => 'I have read this and agree';

  @override
  String get policyDecline => 'I do not agree';

  @override
  String get policyOwnContentBody =>
      'Everything you say, send, or share is on you. Joining a circle means accepting that.';

  @override
  String get policyOwnContentTitle => 'You\'re responsible for what you post';

  @override
  String get policyRemovalBody =>
      'People who break these rules are removed from the circle; serious cases are banned from the service for good. Once we get a report, we finish handling it and tell you the outcome within 24 hours.';

  @override
  String get policyRemovalTitle => 'People who break the rules are removed';

  @override
  String get policySummary =>
      'This is a voice space for small circles of people who already know each other. For it to stay somewhere you want to be, a few things have to hold.';

  @override
  String get policyTitle => 'Community content rules';

  @override
  String get policyToolsBody =>
      'You can block someone on this device at any time; after that you stop receiving anything from them. To report someone, pick them in the member list, or press and hold the specific message.';

  @override
  String get policyToolsTitle => 'You have tools';

  @override
  String get policyZeroToleranceBody =>
      'Harassment, personal attacks, hateful or discriminatory speech, sexual content, violent content, and illegal material aren\'t allowed here. That covers voice, text, pictures, and location, with no exceptions.';

  @override
  String get policyZeroToleranceTitle => 'Zero tolerance for abuse';

  @override
  String recordingAlsoRecording(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count other people in the room are recording',
      one: '1 other person in the room is recording',
    );
    return '$_temp0';
  }

  @override
  String get recordingConsentEveryoneNotified =>
      'Everyone in the room is told right away that you\'re the one recording.';

  @override
  String get recordingConsentLocalOnly =>
      'Audio is transcribed to text and kept on this device. Nothing is uploaded.';

  @override
  String recordingConsentMemberCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'There are $count people in the room right now.',
      one: 'There\'s 1 person in the room right now.',
    );
    return '$_temp0';
  }

  @override
  String get recordingConsentPersistentNotice =>
      'While you record, everyone sees a recording notice they can\'t dismiss.';

  @override
  String get recordingConsentReconsider => 'Let me think';

  @override
  String get recordingConsentStart => 'Start recording';

  @override
  String get recordingConsentTitle => 'Start recording?';

  @override
  String recordingElapsedHours(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hours hours so far',
      one: '1 hour so far',
    );
    return '$_temp0';
  }

  @override
  String recordingElapsedHoursMinutes(int hours, int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hours hours',
      one: '1 hour',
    );
    String _temp1 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minutes',
      one: '1 minute',
    );
    return '$_temp0 $_temp1 so far';
  }

  @override
  String recordingElapsedMinutes(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minutes so far',
      one: '1 minute so far',
    );
    return '$_temp0';
  }

  @override
  String recordingElapsedSeconds(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds seconds so far',
      one: '1 second so far',
    );
    return '$_temp0';
  }

  @override
  String get recordingListSeparator => ', ';

  @override
  String get recordingNobodyRecording => 'Nobody here is recording';

  @override
  String get recordingNoticeAlreadyInProgress =>
      'A recording is already running. Stop it first.';

  @override
  String recordingNoticeArmingTimeout(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds seconds',
      one: '1 second',
    );
    return 'Couldn\'t confirm the room was told, so recording was cancelled (no reply from the server after $_temp0)';
  }

  @override
  String get recordingNoticeCircleIdEmpty =>
      'No circle ID, so recording can\'t start';

  @override
  String get recordingNoticeDisconnected =>
      'Lost the signaling connection. Trying to get it back; recording will stop on its own if it doesn\'t come back';

  @override
  String recordingNoticeGraceExpired(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds seconds',
      one: '1 second',
    );
    return 'Signaling has been down for more than $_temp0. There\'s no way to tell whether the room still knows, so recording stopped';
  }

  @override
  String get recordingNoticeRemovedFromRoom =>
      'You were removed from the room, so recording stopped — the room wouldn\'t have known';

  @override
  String get recordingNoticeServerMarkedInactive =>
      'The server has you marked as not recording, so recording stopped — the room wouldn\'t have known';

  @override
  String get recordingNoticeSignalingSilent =>
      'No signaling messages for a while. Confirming the recording status again';

  @override
  String get recordingNoticeStateOutOfSync =>
      'Signaling state is out of sync. Confirming the recording status again';

  @override
  String recordingSemanticsLabel(String body) {
    return 'Recording notice: $body';
  }

  @override
  String recordingSeveralRecording(String name, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count people are recording, including $name',
      one: '$name is recording',
    );
    return '$_temp0';
  }

  @override
  String recordingSomeoneRecording(String name) {
    return '$name is recording';
  }

  @override
  String get recordingStatusUnconfirmed => 'Recording status unconfirmed';

  @override
  String get recordingStop => 'Stop recording';

  @override
  String get recordingYouAreRecording => 'You\'re recording';

  @override
  String get reportAccepted => 'Sent. We\'ll deal with it within 24 hours';

  @override
  String get reportAction => 'Report';

  @override
  String get reportActionHint =>
      'Tell us what happened — we deal with it within 24 hours';

  @override
  String get reportDeliveryBody =>
      'We\'ve written up the report and opened your email app. Check it over and hit send.\nIf the email didn\'t open, the report is on your clipboard too — start a new message, paste it, and send it to:';

  @override
  String get reportDeliveryFollowUp =>
      'We resolve reports within 24 hours and reply to this address.';

  @override
  String get reportDeliveryTitle => 'One last step: send the email';

  @override
  String reportDialogTitle(String targetName) {
    return 'Report $targetName';
  }

  @override
  String get reportMessageAction => 'Report this message';

  @override
  String get reportNoteHint => 'Anything to add (optional)';

  @override
  String get reportPickReason =>
      'Pick the closest one. We read every report and get back to you.';

  @override
  String get reportReasonHarassment => 'Harassment or personal attacks';

  @override
  String get reportReasonHateSpeech => 'Hate speech or discrimination';

  @override
  String get reportReasonIllegal => 'Illegal or dangerous activity';

  @override
  String get reportReasonOther => 'Something else';

  @override
  String get reportReasonSexualContent => 'Sexual or suggestive content';

  @override
  String get reportReasonSpam => 'Spam or flooding';

  @override
  String get reportReasonViolence => 'Violence or graphic content';

  @override
  String get reportSubmit => 'Submit report';

  @override
  String get roomAloneHere => 'Just you in here. Stay a bit?';

  @override
  String get roomBackToRoom => 'Back to the room';

  @override
  String get roomBlockedSemantics => 'This person is blocked';

  @override
  String get roomEmpty => 'Nobody here yet. Sit a while?';

  @override
  String get roomErrorGeneric => 'Something went wrong';

  @override
  String get roomJoining => 'Going in…';

  @override
  String get roomPasscodeHint => 'Passcode';

  @override
  String get roomPasscodeRetry => 'Try again';

  @override
  String get roomPasscodeSavedElsewhere =>
      'Passcode saved. This server currently uses a shared token, so you\'ll need to switch it to per-circle passcodes in settings before it works.';

  @override
  String get roomJoinLatencyTooltip => 'How long it took to get in';

  @override
  String get roomKickBody =>
      'They\'ll be moved out of the room. They can come back later — this isn\'t a ban.';

  @override
  String get roomKickConfirm => 'Remove';

  @override
  String get roomKickMember => 'Remove from room';

  @override
  String get roomKickMemberHint =>
      'They can come back later, this isn\'t a ban';

  @override
  String roomKickTitle(String name) {
    return 'Remove $name from the room?';
  }

  @override
  String get roomKnockAllow => 'Let them in';

  @override
  String get roomKnockDeny => 'Not now';

  @override
  String get roomKnocking => 'Knocking, waiting for someone to answer…';

  @override
  String roomKnockWants(String name) {
    return '$name wants to come in';
  }

  @override
  String get roomLeave => 'Leave';

  @override
  String get roomLocationMap => 'Shared location map';

  @override
  String get roomMute => 'Mute';

  @override
  String roomPeopleHere(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count people here',
      one: '1 person here',
      zero: 'Nobody here',
    );
    return '$_temp0';
  }

  @override
  String get roomStatusBusy => 'Busy';

  @override
  String get roomStatusEars => 'Just listening';

  @override
  String get roomStatusFree => 'Free to talk';

  @override
  String get roomUnmute => 'Speak';

  @override
  String get settingsAuthModeCircle => 'Per-circle passcode';

  @override
  String get settingsAuthModeNone => 'No passcode';

  @override
  String get settingsAuthModeToken => 'Shared token';

  @override
  String get settingsBackground => 'Keep running in the background';

  @override
  String get settingsBackgroundDenied =>
      'Allow this app to ignore battery optimization in system settings';

  @override
  String get settingsBackgroundGranted =>
      'Background running is allowed. On some Android skins you may also need to turn on auto-start.';

  @override
  String get settingsBackgroundIos =>
      'While you\'re in a room, iOS keeps the app alive with background audio. Nothing to set up.';

  @override
  String get settingsBackgroundSub =>
      'Stay connected while idle: battery optimization exemption / background audio';

  @override
  String get settingsContentPolicy => 'Community content rules';

  @override
  String get settingsContentPolicySub => 'What we ask of what gets shared here';

  @override
  String get settingsDnd => 'Do not disturb hours';

  @override
  String get settingsDndConfirm => 'That\'s it';

  @override
  String get settingsDndFrom => 'From';

  @override
  String get settingsDndOff => 'Off (knocks still come through)';

  @override
  String get settingsDndTo => 'To';

  @override
  String get settingsDndTurnOff => 'Turn off';

  @override
  String get settingsGroupCircle => 'This circle';

  @override
  String get settingsGroupMe => 'You';

  @override
  String get settingsGroupSafety => 'Somewhere you can stay';

  @override
  String get settingsGroupSound => 'Sound and interruptions';

  @override
  String get settingsHomeWidget => 'Put a circle on the home screen';

  @override
  String get settingsHomeWidgetAndroidStep1 =>
      'Press and hold an empty spot on the home screen';

  @override
  String get settingsHomeWidgetAndroidStep2 => 'Tap Widgets';

  @override
  String get settingsHomeWidgetAndroidStep3 => 'Find Lares Circle';

  @override
  String get settingsHomeWidgetAndroidStep4 => 'Drag it onto the home screen';

  @override
  String get settingsHomeWidgetGuideTitle => 'Adding it to the home screen';

  @override
  String get settingsHomeWidgetIosStep1 =>
      'Press and hold an empty spot on the home screen until the icons jiggle';

  @override
  String get settingsHomeWidgetIosStep2 => 'Tap the + in the top left corner';

  @override
  String get settingsHomeWidgetIosStep3 => 'Search for \"Lares Circle\"';

  @override
  String get settingsHomeWidgetIosStep4 =>
      'Pick a size — swipe left or right to see the others';

  @override
  String get settingsHomeWidgetIosStep5 =>
      'Tap Add Widget, then Done in the top right';

  @override
  String get settingsHomeWidgetPhoneOnly =>
      'Home screen widgets are a phone thing. This device doesn\'t have them.';

  @override
  String get settingsHomeWidgetSub =>
      'One tap from the home screen into your main circle';

  @override
  String get settingsIdentityExportBody =>
      'Open the same place over there and paste it into the box below. It only holds your identity and name — no circle passphrases.';

  @override
  String get settingsIdentityExportTitle =>
      'Give this string to the other device';

  @override
  String get settingsIdentityImportAction => 'Use this identity';

  @override
  String get settingsIdentityImportBad =>
      'That does not look like an identity string. Try copying it again.';

  @override
  String get settingsIdentityImportHint => 'lares-id-v1:…';

  @override
  String get settingsIdentityImportRestart =>
      'Saved — but restart Lares before it counts. This connection is still online under the old identity.';

  @override
  String get settingsIdentityImportTitle => 'Or paste one in';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsLanguageSystem => 'Follow system';

  @override
  String get settingsMyName => 'Your name';

  @override
  String get settingsMyNameHint => 'Nickname';

  @override
  String get settingsMyNameTitle => 'What should everyone call you?';

  @override
  String get settingsNoiseEnhanced => 'Enhanced';

  @override
  String get settingsNoiseOff => 'Off';

  @override
  String get settingsNoiseStandard => 'Standard';

  @override
  String get settingsNoiseSuppression => 'Noise suppression';

  @override
  String get settingsPickPrimaryCircle => 'Which one is the main circle?';

  @override
  String get settingsPrimaryCircle => 'Main circle';

  @override
  String get settingsPrimaryCircleNone => 'No circles yet';

  @override
  String settingsPrimaryCircleSub(String name) {
    return '$name\nThe widget, quick settings and the tray all open this one';
  }

  @override
  String get settingsRecording => 'Recording and transcripts';

  @override
  String get settingsRecordingOff =>
      'Off by default; everyone sees a notice when it\'s on';

  @override
  String get settingsRecordingOn =>
      'Recording — everyone in the room can see the notice';

  @override
  String get settingsRecordingStart => 'Start recording';

  @override
  String get settingsRecordingStartFailed => 'Recording didn\'t start';

  @override
  String get settingsRecordingStop => 'Stop recording';

  @override
  String get settingsSameIdentity => 'Use this identity on another device';

  @override
  String get settingsSameIdentitySub =>
      'Your computer and phone count as one person, and will not knock each other offline';

  @override
  String get settingsServer => 'Server and passcode';

  @override
  String get settingsServerAdd => 'Add a server';

  @override
  String get settingsServerAuthLabel => 'Needs a passcode';

  @override
  String get settingsServerBiometricFailed =>
      'Not verified, so it stays closed';

  @override
  String get settingsServerBiometricReason => 'View or change server passcodes';

  @override
  String get settingsServerBuiltIn => 'Default (built in)';

  @override
  String get settingsServerCircleId => 'Circle ID';

  @override
  String get settingsServerCirclePasscode => 'Circle passcode';

  @override
  String settingsServerCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count servers',
      one: '1 server',
    );
    return '$_temp0';
  }

  @override
  String get settingsServerDefaultLabel => 'My server';

  @override
  String get settingsServerDelete => 'Delete';

  @override
  String get settingsServerEdit => 'Edit';

  @override
  String get settingsServerEditTitle => 'Edit server';

  @override
  String get settingsServerListTitle => 'Servers';

  @override
  String get settingsServerName => 'Name';

  @override
  String get settingsServerNameHint => 'e.g. the VPS at home';

  @override
  String get settingsServerPlaintextWarning =>
      'Passcodes are kept as plain text in this device\'s settings, not encrypted. Anyone who can read the files on this device can read them — be careful on a shared device.';

  @override
  String get settingsServerSave => 'Save';

  @override
  String get settingsServerSaved =>
      'Saved. Restart the app for it to take effect.';

  @override
  String get settingsServerTest => 'Test connection';

  @override
  String get settingsServerTokenHint => 'The server\'s LARES_AUTH_TOKEN';

  @override
  String get settingsServerUrl => 'Address';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsWifiOnlyHq => 'High quality on Wi-Fi only';

  @override
  String get settingsWifiOnlyHqSub =>
      'Uses a lower bitrate on mobile data to save it';

  @override
  String get updateAndroidInstallerOpened =>
      'The system installer is open. If it says installing unknown apps is blocked, allow Lares Circle to install apps in the settings screen it offers, then try again.';

  @override
  String get updateAutoCheckSubtitle =>
      'Checks quietly and only speaks up when there\'s a new version. Installing always needs your confirmation.';

  @override
  String get updateAutoCheckTitle => 'Check for updates at startup';

  @override
  String get updateCheckNow => 'Check now';

  @override
  String updateCurrentVersion(String version) {
    return 'Current v$version';
  }

  @override
  String get updateDownload => 'Download update';

  @override
  String get updateDownloading => 'Downloading…';

  @override
  String updateDownloadWithSize(String size) {
    return 'Download update ($size MB)';
  }

  @override
  String get updateErrAndroidInstallerNotOpened =>
      'The system installer didn\'t open.';

  @override
  String updateErrAndroidLaunchFailed(String detail) {
    return 'Couldn\'t open the system installer: $detail';
  }

  @override
  String get updateErrChecksum =>
      'The checksum doesn\'t match. The file may be damaged or tampered with, so it was deleted.';

  @override
  String updateErrDownloadFailed(String detail) {
    return 'The download failed: $detail';
  }

  @override
  String updateErrDownloadHttp(int code) {
    return 'The download failed (HTTP $code).';
  }

  @override
  String get updateErrDownloadTimeout => 'The download timed out.';

  @override
  String updateErrGithubRefused(int code) {
    return 'GitHub turned down the request ($code). Try again later.';
  }

  @override
  String updateErrHttp(int code) {
    return 'The check didn\'t go through (HTTP $code).';
  }

  @override
  String get updateErrInstallFailed => 'The installation didn\'t go through.';

  @override
  String get updateErrIosCannotInstall =>
      'iOS can\'t install an update package from inside the app.';

  @override
  String get updateErrIosNoSelfUpdate =>
      'iOS can\'t update the app from inside itself. Update through TestFlight, or sideload the new .ipa from a computer.';

  @override
  String get updateErrMalformed =>
      'The release data came back in an unexpected shape and couldn\'t be read.';

  @override
  String get updateErrNoAsset =>
      'There\'s no downloadable package for this platform.';

  @override
  String get updateErrNoReleases => 'The repository has no releases yet.';

  @override
  String get updateErrNotDownloaded => 'There\'s no downloaded package yet.';

  @override
  String get updateErrOffline =>
      'No network connection, so updates can\'t be checked right now.';

  @override
  String get updateErrRateLimited =>
      'The GitHub API quota is used up (60 requests per hour when signed out). Try again later.';

  @override
  String updateErrRateLimitedUntil(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other:
          'The GitHub API quota is used up (60 requests per hour when signed out), it comes back in about $minutes minutes. Try again later.',
      one:
          'The GitHub API quota is used up (60 requests per hour when signed out), it comes back in about 1 minute. Try again later.',
    );
    return '$_temp0';
  }

  @override
  String updateErrSizeMismatch(int expected, int actual) {
    return 'The downloaded file is the wrong size (expected $expected bytes, got $actual), so it was deleted.';
  }

  @override
  String get updateErrTimeout =>
      'The network timed out, so updates can\'t be checked right now.';

  @override
  String updateErrUnknownVersion(String version) {
    return 'Couldn\'t make sense of the current version number ($version)';
  }

  @override
  String updateErrWinLaunchFailed(String detail) {
    return 'Couldn\'t start the installer: $detail';
  }

  @override
  String get updateErrWinNoInstallDir =>
      'The install folder couldn\'t be found. You can download the new version and install over the old one yourself.';

  @override
  String get updateErrWinNotWritable =>
      'The install folder isn\'t writable, usually because Lares sits in Program Files and isn\'t running as administrator. Download the new version manually, or move Lares into your user folder and try again.';

  @override
  String updateErrWinPackageInvalid(String name) {
    return 'The update package looks wrong ($name wasn\'t in it). Nothing was changed, your current version is untouched.';
  }

  @override
  String updateErrWinProbeFailed(String detail) {
    return 'Couldn\'t tell whether the install folder is writable: $detail';
  }

  @override
  String updateErrWinUnzipFailed(String detail) {
    return 'Unpacking the update failed: $detail';
  }

  @override
  String get updateGotIt => 'Got it';

  @override
  String get updateInstallAndRestart => 'Install and restart';

  @override
  String get updateInstallConfirmBody =>
      'Lares will close, replace its program files and start again on its own.\nIf you\'re talking in a circle, you\'ll be disconnected first.';

  @override
  String get updateInstallConfirmTitle => 'Install the update now?';

  @override
  String get updateInstallNow => 'Install now';

  @override
  String get updateInstallStarted => 'Installation started.';

  @override
  String get updateIntegrityFull =>
      'Integrity: the file size matches, and the SHA-256 matches the checksum published in the release notes.';

  @override
  String get updateIntegrityNone =>
      'Integrity: nothing could be verified, the release gave no file size.';

  @override
  String get updateIntegritySizeOnly =>
      'Integrity: only the file size was checked against what GitHub reports. The release notes gave no checksum, so the contents can\'t be verified; transport safety relies on HTTPS.';

  @override
  String get updateLater => 'Later';

  @override
  String get updateMacosDragToApps =>
      'The new version is open in Finder:\n1. Quit Lares if it\'s running;\n2. Drag the new lares_app.app into Applications and choose replace;\n3. If the first launch says the developer can\'t be verified, right-click the icon and choose Open.';

  @override
  String get updateNextStepsTitle => 'What to do next';

  @override
  String get updateNoReleaseNotes => '(No release notes for this version)';

  @override
  String get updateNoticeIos =>
      'iOS can\'t update from inside the app. If you installed through TestFlight, update there; if you sideloaded with a free signature, the signature expires after 7 days and you need a computer to sideload the new .ipa again.';

  @override
  String get updateNoticeMacos =>
      'On macOS you drag the new version into Applications yourself. Finder opens automatically once the download finishes.';

  @override
  String get updateNoticeNoAssetForPlatform =>
      'This version has no downloadable package for your platform. You can get it manually from the GitHub Releases page.';

  @override
  String get updateNoticeWeb =>
      'The web version updates with the server: a hard refresh (Ctrl/Cmd + Shift + R) is enough.';

  @override
  String get updateQuitting => 'Quitting to finish the update…';

  @override
  String get updateRevealFolder => 'Show in folder';

  @override
  String updateStatusAvailable(String version) {
    return 'New version available: v$version';
  }

  @override
  String get updateStatusCheckFailed => 'The check didn\'t go through.';

  @override
  String get updateStatusChecking => 'Checking…';

  @override
  String get updateStatusDownloading => 'Downloading the update…';

  @override
  String get updateStatusIdle => 'No update check yet.';

  @override
  String get updateStatusReady => 'Download finished, ready to install.';

  @override
  String get updateStatusUpToDate => 'You\'re on the latest version.';

  @override
  String get updateTitle => 'Version and updates';

  @override
  String get updateVersionUnknown => 'Current version unknown';

  @override
  String get updateWinRestarting =>
      'Quitting to finish the update, Lares comes back in a few seconds.';

  @override
  String get widgetNoCircle => 'No circle yet';

  @override
  String get widgetNoCircleHint => 'Open the app and make one';

  @override
  String get widgetNobodyHere => 'Nobody here. Go in and wait a bit?';

  @override
  String widgetPeopleHere(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count people here',
      one: '1 person here',
    );
    return '$_temp0';
  }

  @override
  String widgetPeopleHereWithNames(int count, String names) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count people here · $names',
      one: '1 person here · $names',
    );
    return '$_temp0';
  }
}
