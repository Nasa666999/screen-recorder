"""保留完整全局特征，只缩小局部重建所需的末端计算。"""

import shutil
import sys
import tempfile
from pathlib import Path

import coremltools as ct
import numpy as np
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil import Function, Program
from coremltools.converters.mil.frontend.milproto.load import load
from coremltools.converters.mil.mil import types


def mapped(value, variables):
    """业务作用: 将原程序参数连接到派生程序，保留参数值及运算顺序。

    参数说明:
    - value: 原程序中的张量或张量序列。
    - variables: 原张量名称与已创建张量的对应关系。
    返回: 对应的派生张量；缺失连接时拒绝生成模型。
    """
    if isinstance(value, (list, tuple)):
        return type(value)(mapped(item, variables) for item in value)
    return variables[value.name]


def prepare(source, destination):
    """业务作用: 从固定来源生成保留八百像素上下文和全精度参数的局部重建模型。

    参数说明:
    - source: 已验证 SHA-256 的原始 LaMa 模型包。
    - destination: 构建缓存中的派生模型包位置。
    返回: 完整生成后替换缓存；来源结构不符合局部依赖约束时停止构建。
    """
    specification = ct.models.utils.load_spec(
        str(source / "Data/com.apple.CoreML/model.mlmodel")
    )
    original = load(
        specification,
        specification_version=int(ct.target.macOS15),
        file_weights_dir=str(source / "Data/com.apple.CoreML/weights"),
    ).functions["main"]
    if (
        tuple(original.inputs["image"].shape) != (1, 3, 800, 800)
        or tuple(original.inputs["mask"].shape) != (1, 1, 800, 800)
    ):
        raise ValueError("来源模型必须保留八百像素的完整输入。")
    upsampling = [op for op in original.operations if op.op_type == "conv_transpose"]
    if (
        len(upsampling) != 3
        or tuple(upsampling[0].x.shape) != (1, 512, 100, 100)
        or any(
            tuple(op.weight.shape[2:]) != (3, 3)
            or tuple(op.strides.val) != (2, 2)
            for op in upsampling
        )
    ):
        raise ValueError("来源模型的末端重建结构不受支持。")
    operations = list(original.operations)
    decoder = operations[operations.index(upsampling[0]) :]
    allowed = {
        "const",
        "conv_transpose",
        "crop",
        "batch_norm",
        "relu",
        "pad",
        "conv",
        "sigmoid",
        "mul",
        "add",
        "clip",
    }
    convolutions = [op for op in decoder if op.op_type == "conv"]
    if (
        any(op.op_type not in allowed for op in decoder)
        or len(convolutions) != 1
        or tuple(convolutions[0].weight.shape[2:]) != (7, 7)
        or any(
            op.op_type == "batch_norm"
            and (op.mean.val is None or op.variance.val is None)
            for op in decoder
        )
    ):
        raise ValueError("末端重建必须只依赖局部卷积和固定归一化参数。")

    cells = 48
    edge = cells * 8
    placeholders = {
        "image": mb.placeholder(shape=(1, 3, 800, 800)),
        "mask": mb.placeholder(shape=(1, 1, 800, 800)),
        "origin": mb.placeholder(shape=(2,), dtype=types.int32),
    }
    variables = {}
    cropped = {}
    with Function(placeholders, opset_version=ct.target.macOS15) as main:
        variables.update(main.inputs)
        zeros = mb.const(val=np.array([0, 0], dtype=np.int32))
        feature_begin = mb.concat(values=[zeros, main.inputs["origin"]], axis=0)
        image_begin = mb.concat(
            values=[zeros, mb.mul(x=main.inputs["origin"], y=np.int32(8))], axis=0
        )
        started = False
        final = False
        for op in original.operations:
            if op.op_type == "const":
                variables[op.outputs[0].name] = mb.const(val=op.val.val, name=op.name)
                continue
            arguments = {
                key: mapped(value, variables)
                for key, value in op.inputs.items()
                if value is not None
            }
            if op.op_type == "conv_transpose":
                if not started:
                    # 傅里叶全局特征全部计算完成后才取局部；不能裁掉模型感知到的来源上下文。
                    arguments["x"] = mb.slice_by_size(
                        x=arguments["x"], begin=feature_begin, size=[1, 512, cells, cells]
                    )
                    started = True
                shape = list(op.output_shape.val)
                for axis in (2, 3):
                    shape[axis] = (
                        2 * arguments["x"].shape[axis]
                        + shape[axis]
                        - 2 * op.x.shape[axis]
                    )
                arguments["output_shape"] = shape
            if final:
                for key, value in list(arguments.items()):
                    if (
                        hasattr(value, "shape")
                        and len(value.shape) == 4
                        and value.shape[2:] == (800, 800)
                    ):
                        if value.name not in cropped:
                            cropped[value.name] = mb.slice_by_size(
                                x=value,
                                begin=image_begin,
                                size=[1, value.shape[1], edge, edge],
                            )
                        arguments[key] = cropped[value.name]
            output = getattr(mb, op.op_type)(name=op.name, **arguments)
            outputs = output if isinstance(output, (list, tuple)) else [output]
            for before, after in zip(op.outputs, outputs):
                variables[before.name] = after
            if op.op_type == "sigmoid" and started:
                final = True
        output = variables[original.outputs[0].name]
        output.name = "output"
        main.set_outputs([output])
        main.set_input_types(
            (
                ct.ImageType(
                    name="image",
                    shape=(1, 3, 800, 800),
                    scale=1,
                    color_layout=ct.colorlayout.RGB,
                    channel_first=True,
                ),
                ct.ImageType(
                    name="mask",
                    shape=(1, 1, 800, 800),
                    scale=1,
                    color_layout=ct.colorlayout.GRAYSCALE,
                    channel_first=True,
                ),
                ct.TensorType(name="origin", shape=(2,), dtype=np.int32),
            )
        )
        main.set_output_types(
            [
                ct.ImageType(
                    name="output",
                    color_layout=ct.colorlayout.RGB,
                    channel_first=True,
                )
            ]
        )
    program = Program()
    program.add_function("main", main)
    model = ct.convert(
        program,
        source="milinternal",
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT32,
        skip_model_load=True,
    )
    staged = Path(tempfile.mkdtemp(dir=destination.parent)) / destination.name
    try:
        model.save(str(staged))
        # 新程序完整生成后才替换构建缓存，生成失败不能留下可被打包的半成品。
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(str(staged), str(destination))
    finally:
        shutil.rmtree(staged.parent)


def main():
    """业务作用: 约束生成工具和临时文件位置，完成本地派生模型缓存。

    参数说明: 无。
    返回: 接收来源与目标两个命令参数，失败时不产出新的模型包。
    """
    if len(sys.argv) != 3 or ct.__version__ != "9.0":
        raise ValueError("需要 coremltools 9.0，以及来源和目标模型包两个参数。")
    source = Path(sys.argv[1]).resolve()
    destination = Path(sys.argv[2]).resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    previous = tempfile.tempdir
    with tempfile.TemporaryDirectory(
        prefix="lama-generation-", dir=destination.parent
    ) as temporary:
        tempfile.tempdir = temporary
        try:
            prepare(source, destination)
        finally:
            tempfile.tempdir = previous


if __name__ == "__main__":
    main()
