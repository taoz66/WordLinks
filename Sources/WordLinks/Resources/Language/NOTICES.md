# 词形数据来源与修改说明

本包含 SPECIALIST Lexicon 2026（U.S. National Library of Medicine / NIH）及 Open English WordNet 2025 的派生数据。它们保留各自条款；不可将整个混合包统一标为 MIT 或 CC BY。

- SPECIALIST：官方 2026 inflection.table，服务端 Last-Modified 为 2025-12-17；下载时间、完整 URL 和校验值见原始 sources.json。原样条款见 [SPECIALIST-terms.html](LICENSES/SPECIALIST-terms.html)。其内容为美国政府产品，项目不对其主张专有权利；不以机构名称为本产品背书。
- Open English WordNet 2025：John P. McCrae 等及贡献者，继承 Princeton WordNet 材料；见 [CC BY 4.0](LICENSES/OEWN-CC-BY-4.0.md) 和 [Princeton 声明](LICENSES/Princeton-WordNet.txt)。

修改：原始表无损压缩存档；逐行验证字段和代码，隔离多单位和控制字符条目；提取精确写法的 surface→BAS（第七列）关系，保留原词头自身；按精确 form+lemma 去重并保留来源掩码；词性、时态及引用保存在 evidence.tsv.gz；增加已有 WordNet 的词头和显式 form 关系，保留每份输入的校验值。不使用 CIT（第八列）强制改拼写，不生成新变形，不合并大小写、重音、连字符、英美拼写、同义词或派生词。负式、变化后的情态词及仅由无词形标签的 WordNet form 提供的关系带审查标志，不因词形还原移除否定；自动建议边界见 README。

本目录随 WordLinks 独立提供 `lexicon.sqlite3`、上游许可和本署名/修改说明，运行时不依赖其他项目。索引最初来自 ReadingTool 原生阅读实验的已生成数据；本项目不包含索引生成脚本、原始输入、`sources.json` 或 `evidence.tsv.gz`。上文对这些文件的描述记录了历史生成过程，不表示这些材料已经随本项目分发。
