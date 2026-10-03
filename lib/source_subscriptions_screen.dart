import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'local_store.dart';
import 'source_subscriptions.dart';

class SourceSubscriptionsScreen extends StatefulWidget {
  const SourceSubscriptionsScreen({super.key,required this.store});
  final LocalStore store;
  @override State<SourceSubscriptionsScreen> createState()=>_SourceSubscriptionsScreenState();
}
class _SourceSubscriptionsScreenState extends State<SourceSubscriptionsScreen> {
  final manager=SourceSubscriptions.instance;
  final address=TextEditingController(text:SourceSubscriptions.officialRepository);
  SourceSubscriptionPreview? preview;
  final selected=<String>{};
  bool working=false;
  String error='';
  @override void initState(){super.initState();manager.addListener(changed);}
  void changed(){if(mounted)setState((){});}
  @override void dispose(){manager.removeListener(changed);address.dispose();super.dispose();}
  Future<void> run(Future<void> Function() action)async{
    if(working)return;setState((){working=true;error='';});
    try{await action();}catch(exception){if(mounted)setState(()=>error=exception is FormatException?exception.message.toString():'操作失败，原站源与用户配置已保留');}
    finally{if(mounted)setState(()=>working=false);}
  }
  Future<void> load()=>run(()async{final result=await manager.preview(address.text);if(mounted)setState((){preview=result;selected.clear();});});
  Future<void> install()=>run(()async{
    final current=preview;if(current==null)return;
    final epoch=widget.store.profileEpoch;
    final failures=<String>[];final installed=<String,bool>{};
    for(final entry in current.entries.where((row)=>selected.contains(row['id']))){
      if(epoch!=widget.store.profileEpoch)break;
      try{await manager.install(current,entry);installed[entry['id'] as String]=true;}
      catch(_){failures.add(entry['name'] as String);}
    }
    if(epoch==widget.store.profileEpoch && installed.isNotEmpty)await widget.store.setSourcesVisible(installed);
    if(failures.isNotEmpty)throw FormatException('以下站源未导入，其余已保留：${failures.join('、')}');
    if(mounted)setState(()=>selected.clear());
  });
  Future<void> update(String id)=>run(()async{
    final origin=manager.package(id)!.origin;
    final current=await manager.preview(origin);
    if(!mounted)return;
    final entry=current.entries.where((row)=>row['id']==id).firstOrNull;
    if(entry==null)throw const FormatException('上游已移除此站源，本地版本仍保留');
    final accepted=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(title:Text('更新 ${entry['name']}'),content:SingleChildScrollView(child:Text('版本：${manager.package(id)!.version} → ${entry['version']}\n${entry['changelog']??''}\n\n允许请求：${(entry['domains'] as List? ?? []).join('、')}\n站源脚本由此订阅仓库提供。')),actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('取消')),FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('更新站源'))]));
    if(accepted==true)await manager.install(current,entry);
  });
  Future<void> remove(String id)=>run(()async{
    final accepted=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(title:const Text('移除站源'),content:const Text('移除订阅与站源程序。观看记录、收藏和本地账号配置保留，重新导入相同站源后仍可使用。'),actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('取消')),TextButton(onPressed:()=>Navigator.pop(context,true),child:const Text('移除'))]));
    if(accepted==true)await manager.remove(id);
  });
  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('站源订阅'),actions:[IconButton(tooltip:'检查站源更新',onPressed:working||manager.checking?null:()=>run(manager.checkUpdates),icon:const Icon(Icons.system_update_alt_rounded))]),
    body:Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:800),child:ListView(padding:const EdgeInsets.all(16),children:[
      Card.outlined(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('添加订阅',style:Theme.of(context).textTheme.titleMedium),const SizedBox(height:12),
        TextField(controller:address,enabled:!working,keyboardType:TextInputType.url,decoration:const InputDecoration(labelText:'GitHub 仓库、订阅或单个站源链接',border:OutlineInputBorder()),onSubmitted:(_)=>load()),const SizedBox(height:12),
        Wrap(spacing:8,runSpacing:8,children:[FilledButton.icon(onPressed:working?null:load,icon:const Icon(Icons.cloud_download_outlined),label:const Text('获取站源列表')),OutlinedButton.icon(onPressed:working?null:()=>run(()async{final result=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['json']);final file=result?.files.single.path;if(file!=null)await manager.importLocal(file);}),icon:const Icon(Icons.file_open_outlined),label:const Text('导入本地站源'))]),
        const SizedBox(height:12),const Text('导入后在设备本地运行，更新站源无需重新安装应用。请选择你信任的订阅仓库。Cookie 只保存在本机，不会上传到订阅仓库。'),
      ]))),
      if(working||manager.checking)const Padding(padding:EdgeInsets.all(16),child:LinearProgressIndicator()),
      if(error.isNotEmpty)Padding(padding:const EdgeInsets.all(12),child:Text(error,style:TextStyle(color:Theme.of(context).colorScheme.error))),
      if(preview!=null)...[
        Padding(padding:const EdgeInsets.symmetric(vertical:12),child:Text(preview!.name,style:Theme.of(context).textTheme.titleMedium)),
        Wrap(spacing:8,children:[TextButton(onPressed:working?null:()=>setState(()=>selected.addAll(preview!.entries.map((entry)=>entry['id'] as String))),child:const Text('全选')),TextButton(onPressed:working?null:()=>setState(()=>selected.clear()),child:const Text('清空选择'))]),
        for(final entry in preview!.entries)Card.outlined(child:CheckboxListTile(value:selected.contains(entry['id']),onChanged:working?null:(value)=>setState((){if(value==true){selected.add(entry['id'] as String);}else{selected.remove(entry['id']);}}),title:Text('${entry['name']} · ${entry['version']}'),subtitle:Text('${entry['description']??''}\n请求域名：${(entry['domains'] as List? ?? []).join('、')}'))),
        Align(alignment:Alignment.centerLeft,child:FilledButton(onPressed:working||selected.isEmpty?null:install,child:Text('导入并订阅 ${selected.length} 个站源'))),const SizedBox(height:24),
      ],
      Text('已安装站源 · ${manager.installed.length}',style:Theme.of(context).textTheme.titleMedium),
      if(manager.installed.isEmpty)const Padding(padding:EdgeInsets.symmetric(vertical:20),child:Text('应用不预装站源，请先添加订阅。')),
      for(final package in manager.installed)Card.outlined(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('${package.name} · ${package.version}',style:Theme.of(context).textTheme.titleMedium),const SizedBox(height:4),Text(package.origin,maxLines:2,overflow:TextOverflow.ellipsis),
        Wrap(spacing:8,children:[if(manager.updates.containsKey(package.id))FilledButton.icon(onPressed:working?null:()=>update(package.id),icon:const Icon(Icons.update),label:const Text('有更新')),TextButton(onPressed:working?null:()=>run(()async{await manager.checkUpdates();}),child:const Text('检查更新')),if(manager.previousVersion(package.id)!=null)TextButton(onPressed:working?null:()=>run(()=>manager.rollback(package.id)),child:Text('回退 ${manager.previousVersion(package.id)}')),IconButton(tooltip:'复制独立订阅链接',onPressed:()=>Clipboard.setData(ClipboardData(text:package.origin)),icon:const Icon(Icons.link)),IconButton(tooltip:'移除站源',onPressed:working?null:()=>remove(package.id),icon:const Icon(Icons.delete_outline))]),
      ]))),
      for(final issue in manager.problems.values)Padding(padding:const EdgeInsets.all(8),child:Text(issue)),
      const SizedBox(height:24),
    ]))),
  );
}
