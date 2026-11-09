// Parses a query and constant-folds the expressions of its YIELD sentences, as graphd's YieldValidator does.
#include "common/base/Base.h"
#include "graph/util/ExpressionUtils.h"
#include "parser/GQLParser.h"
#include "parser/SequentialSentences.h"
#include "parser/TraverseSentences.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  nebula::graph::QueryContext qctx;
  nebula::GQLParser parser(&qctx);
  const char* ptr = reinterpret_cast<const char*>(data);
  auto result = parser.parse(std::string(ptr, size));
  if (!result.ok()) return 0;
  auto sentence = std::move(result).value();
  if (sentence->kind() != nebula::Sentence::Kind::kSequential) return 0;
  auto* seq = static_cast<nebula::SequentialSentences*>(sentence.get());
  for (auto* s : seq->sentences()) {
    if (s->kind() != nebula::Sentence::Kind::kYield) continue;
    for (auto* col : static_cast<nebula::YieldSentence*>(s)->columns()) {
      if (col->expr() == nullptr) continue;
      (void)nebula::graph::ExpressionUtils::foldConstantExpr(col->expr());
    }
  }
  return 0;
}
