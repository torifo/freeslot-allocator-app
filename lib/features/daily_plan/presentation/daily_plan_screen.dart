import 'package:flutter/material.dart';

class DailyPlanScreen extends StatelessWidget {
  const DailyPlanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('日次計画')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                '日次計画は次の段階で実装します。現在は TaskMaster とカテゴリ設定を先に固め、\n'
                '自由時間枠・日またぎ・割り当てロジックを後続の feature として追加する前提です。',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
